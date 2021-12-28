#!/usr/bin/env bash

# store current declared variables
declare -- | grep '^[a-z_]*=' | sed 's#=.*##g' > vardiffbefore

# configurable variables in .env file

php_version=7.4
magento_distribution=project-community-edition
magento_version=2.4
mariadb_version=10.2
mysqldb_version=5.7
elastic_version=7.6.2

site_domain=testingmag2.localhost
backend_email=testing@magento2.com
backend_user=admin
backend_password=Admin123

web_port=80
web_port_secure=443
mailserver_port=1080
mysql_root_password=root
mysql_database=magento
mysql_user=maguser
mysql_password=magpass
mysql_port=3306
pma_port=8081
pma_user=root
pma_password=root
redis_port=6379

web_host=web0
pma_host=phpmyadmin
mysql_host=mysql0
redis_host=redis0
elast_host=elast0
mailserver_host=mailserver

redis_db_session_save=4
redis_db_page_cache=3
redis_db_backend=2

# non-configurable variables

magento_repository_url=https://repo.magento.com/

# mark variables to export to .env file
declare -- | grep '^[a-z_]*='  | sed 's#=.*##g' > vardiffafter

# https://devdocs.magento.com/guides/v2.3/install-gde/system-requirements.html#system-dependencies
system_dep=$(cat << DEP
unzip
gzip
lsof
bash
mariadb-client
#nice
sed
tar
DEP
)

deps=$(cat << EXT
ext-bcmath
ext-ctype
ext-curl
ext-dom
ext-fileinfo
ext-gd
ext-hash
ext-iconv
ext-intl
ext-json
ext-libxml
ext-mbstring
ext-openssl
ext-pcre
ext-pdo_mysql
ext-simplexml
ext-soap
ext-sockets
ext-sodium
ext-xmlwriter
ext-xsl
ext-zip
lib-libxml
lib-openssl
EXT
)

extensions=$(printf '%s\n' $deps | grep '^ext' | sed 's#^....##g')
libraries=$(printf '%s\n' $deps | grep '^lib' | sed 's#^....##g')


# check that target directory is empty
if [ $(find . | grep -v vardiff | wc -l) -ne 1 ]; then
  echo target directory not empty
  (find . | head -n6; echo '...')  | sed 's#^#  > #g'
  if [[ "$@" =~ --overwrite ]]; then
    echo overwriting directory content
  else
    echo to force install please specify --overwrite
    echo '  > '"$0 $@ --overwrite"
    exit 1
  fi
fi

# create env file
declare -a save_vars
IFS="," read -r -a save_vars <<< $(
  echo $(
    diff vardiffbefore vardiffafter | \
    grep '^>' | \
    sed 's#^..##g') | \
    sed 's# #,#g'\
)
rm vardiff*

printf '' > .env
for varname in ${save_vars[@]}; do
  declare -p $varname | sed 's#declare -- ##g' >> .env
done

# create credentials
cat << EOF > auth.json
{
  "http-basic": {
    "repo.magento.com": {
      "username": "xxx",
      "password": "xxx"
    }
  }
}
EOF


# create docker container
cat << EOF > docker-compose.yml
version: '3'
services:
    ${web_host}:
        build: config/${web_host}
        env_file: .env
        ports:
          - "\${web_port}:80"
          - "\${web_port_secure}:443"
#        volumes:
#        - ./config/${web_host}/filesystem/magento/env.php:/magento/app/etc/env.php
        volumes_from:
        - appdata
        - magentodata
        depends_on:
        - \${mysql_host}
        - \${redis_host}
        - \${elast_host}
        - \${mailserver_host}
        links:
        - \${mysql_host}
        - \${redis_host}
        - \${elast_host}
        - \${mailserver_host}
    appdata:
        image: alpine:latest
        volumes:
          - ./system:/magento:cached
          - ./bin:/tools
          - ./auth.json:/root/.composer/auth.json
    magentodata:
        image: alpine:latest
        volumes:
          - ./config/appdata/startup.sh:/startup.sh
          - ./config/\${web_host}/filesystem/magento/var/:/magento/var/
          - ./config/\${web_host}/filesystem/etc/apache2/sites-available/000-default.conf:/etc/apache2/sites-available/000-default.conf
          - ./config/\${web_host}/filesystem/magento/generated/:/magento/generated/
          - ./config/\${web_host}/filesystem/magento/pub/static/:/magento/pub/static/
          - ./config/\${web_host}/filesystem/magento/media/catalog:/magento/pub/media/catalog
          - ./config/\${web_host}/filesystem/magento/media/wysiwyg:/magento/pub/media/wysiwyg
          - ./auth.json:/magento/auth.json
          - ./auth.json:/magento/var/composer_home/auth.json
          - /home/${USER}/.composer:/root/.composer/
          - /home/${USER}/.composer:/magento/var/composer_home/
        command: /bin/sh /startup.sh
    ${mailserver_host}:
      image: reachfive/fake-smtp-server
      env_file: .env
      ports:
          - "\${mailserver_port}:1080"
    ${mysql_host}:
      image: mysql:\${mysqldb_version}
      env_file: .env
      environment:
        MYSQL_ROOT_PASSWORD: \${mysql_root_password}
        MYSQL_DATABASE: \${mysql_database}
        MYSQL_USER: \${mysql_user}
        MYSQL_PASSWORD: \${mysql_password}
      volumes:
        - ./data/:/data/
        #- ./config/setup/init/config-magento.sql:/docker-entrypoint-initdb.d/02-init.sql
    ${elast_host}:
      image: elasticsearch:\${elastic_version}
      env_file: .env
      environment:
        - "discovery.type=single-node"
    ${pma_host}:
        image: phpmyadmin/phpmyadmin:latest
        env_file: .env
        environment:
          - MYSQL_ROOT_PASSWORD=\${mysql_root_password}
          - PMA_USER=\${pma_user}
          - PMA_PASSWORD=\${pma_password}
        ports:
          - "\${pma_port}:80"
        links:
          - \${mysql_host}:db
        depends_on:
          - \${mysql_host}
    ${redis_host}:
      image: redis:latest
      env_file: .env
      ports:
        - "\${redis_port}:6379"
volumes:
    db-data:
        external: false
EOF

function filter-list
{
  sed 's/#.*//g' | grep -v '^$'
}

# helper map for configure extensions in php containers
declare -A phpextconfigure
if [[ ${php_version} > 7 ]]; then
  phpextconfigure=(["gd"]="RUN docker-php-ext-configure gd --with-jpeg=/usr/lib/ --with-freetype")
else
  phpextconfigure=(["gd"]="RUN docker-php-ext-configure gd --with-jpeg-dir=/usr/lib/ --with-freetype-dir")
fi

# helper function to create extension install scripts
function install_extensions_string {
  local install_string="$1"
  local extensions="$2"
  local install_extensions=""
  
  for extension in $extensions; do
    if [ ! -z "${phpextconfigure[$extension]}" ]; then
      install_extensions="${install_extensions}
    ${phpextconfigure[$extension]}"
    fi

    install_extensions="${install_extensions}
    RUN ${install_string}${extension}"
  done
  printf '%s' "$install_extensions"
}


# create Dockerfile for composer container
# use https://github.com/hirak/prestissimo
mkdir -p /home/${USER}/.composer
which rsync 
if [ $? -eq 0 ]; then
  rsync -rcv $(dirname $0)/config/composer/cache/ /home/${USER}/.composer/
else
  cp -Rv $(dirname $0)/config/composer/cache /home/${USER}/.composer
fi

# create Dockerfile for web container
docker run --rm php:${php_version}-apache php -m | grep -v '\[' | filter-list | grep -v '^$' > .extensions_already_included
install_extensions=$(
  install_extensions_string 'docker-php-ext-install ' "$(printf '%s\n' ${extensions} | \
  grep -vFx -f .extensions_already_included)"
)

install_dependencies=$(printf '%s\n' ${system_dep} | filter-list | sed 's#^#RUN apt-get install -y #g')
#install_extensions=$(printf '%s\n' ${extensions} | grep -vFx -f .extensions_already_included | sed 's#^#RUN docker-php-ext-install #g')
mkdir -p config/${web_host}/
cat << DOCKERFILE > config/${web_host}/Dockerfile
FROM php:${php_version}-apache


RUN apt-get update
${install_dependencies}

RUN apt-get install -y libpng-dev \
    libjpeg-dev \
    libwebp-dev \
    libfreetype6-dev \
    libzip-dev \
    libxml2-dev \
    libxslt-dev \
    libcurl4-openssl-dev \
    libonig-dev

# see https://devdocs.magento.com/guides/v2.3/install-gde/system-requirements-tech.html#required-php-extensions
# see https://devdocs.magento.com/guides/v2.4/install-gde/system-requirements.html
${install_extensions}

RUN apt-get purge -y --auto-remove

RUN cd /etc/apache2/mods-enabled && ln -s ../mods-available/rewrite.load rewrite.load

RUN cd /usr/local/bin/ && \
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
    php composer-setup.php && \
    php -r "unlink('composer-setup.php');" && \
    ln -s composer.phar composer && \
    composer self-update --1

RUN cp /usr/local/etc/php/php.ini-development  /usr/local/etc/php/php.ini
RUN sed -i 's#memory_limit.*#memory_limit=-1#g' /usr/local/etc/php/php.ini
WORKDIR /magento
DOCKERFILE

# create virtualhost
mkdir -p config/${web_host}/filesystem/etc/apache2/sites-available/
cat << APACHE_VIRTUALHOST > config/${web_host}/filesystem/etc/apache2/sites-available/000-default.conf
<VirtualHost *:80>
        # The ServerName directive sets the request scheme, hostname and port that
        # the server uses to identify itself. This is used when creating
        # redirection URLs. In the context of virtual hosts, the ServerName
        # specifies what hostname must appear in the request's Host: header to
        # match this virtual host. For the default virtual host (this file) this
        # value is not decisive as it is used as a last resort host regardless.
        # However, you must set it for any further virtual host explicitly.
        #ServerName www.example.com
        PassEnv ORIGIN_MEDIA_URL

        ServerAdmin webmaster@localhost
        DocumentRoot /magento/pub

        # Available loglevels: trace8, ..., trace1, debug, info, notice, warn,
        # error, crit, alert, emerg.
        # It is also possible to configure the loglevel for particular
        # modules, e.g.
        #LogLevel info ssl:warn

        <Directory /magento/pub>
            Options Indexes FollowSymLinks
            AllowOverride All
            Require all granted
        </Directory>

        ErrorLog ${APACHE_LOG_DIR}/error.log
        CustomLog ${APACHE_LOG_DIR}/access.log combined

        # For most configuration files from conf-available/, which are
        # enabled or disabled at a global level, it is possible to
        # include a line for only one particular virtual host. For example the
        # following line enables the CGI configuration for this host only
        # after it has been globally disabled with "a2disconf".
        #Include conf-available/serve-cgi-bin.conf

</VirtualHost>
APACHE_VIRTUALHOST

# create magento configuration
mkdir -p config/${web_host}/filesystem/magento/
cat << MAGENTO_ENV > config/${web_host}/filesystem/magento/env.php
<?php
return [];
MAGENTO_ENV

mkdir -p config/${web_host}/filesystem/magento/
pushd    config/${web_host}/filesystem/magento/
mkdir -p generated/
mkdir -p log/
mkdir -p media/catalog/
mkdir -p media/wysiwyg/
mkdir -p pub/static/
mkdir -p var/
echo '*' \
  > generated/.gitignore \
  > log/.gitignore \
  > media/catalog/.gitignore \
  > media/wysiwyg/.gitignore \
  > pub/static/.gitignore \
  > var/.gitignore
popd

cat << HTACCESSDENY > config/${web_host}/filesystem/magento/generated/.htaccess
<IfVersion < 2.4>
    order allow,deny
    deny from all
</IfVersion>
<IfVersion >= 2.4>
    Require all denied
</IfVersion>


HTACCESSDENY


www_data_user_id=$(docker run --rm php:${php_version}-apache cat /etc/passwd \
  | grep www-data | awk -F ':' '{print $3}')
mkdir -p config/appdata/
cat << WEB_STARTUP > config/appdata/startup.sh
#!/bin/sh
#
# Set the correct file permissions for Magento
# at startup.

# chgrp -R 33 /var/www
# chmod -R g+rs /var/www

chmod 777 /magento/var
chmod 777 /magento/var/*
mkdir /magento/var/log 2>/dev/null
touch /magento/var/log/system.log
ls -laht /magento/var/log
chmod -R 777 /magento/var/log
mkdir /magento/var/locks 2>/dev/null
chmod -R 777 /magento/var/locks
mkdir /magento/var/cache 2>/dev/null
chmod -R 777 /magento/var/cache
mkdir /magento/media 2>/dev/null
chmod -R 777 /magento/media
mkdir /magento/media/wysiwyg 2>/dev/null
chmod -R 777 /magento/media/wysiwyg
mkdir -p /magento/media/catalog/product 2>/dev/null
chmod -R 777 /magento/media/catalog/product
mkdir /magento/generated/ 2>/dev/null
chmod -R 777 /magento/generated/
mkdir /magento/pub/static/ 2>/dev/null
mkdir -p /magento/pub/media/catalog/product
chmod -R 777 /magento/pub
mkdir -p /magento/var/view_preprocessed/pub/static
chmod -R 777 /magento/var/*

cd /magento
find var generated vendor pub/static pub/media app/etc -type f -exec chmod g+w {} +
find var generated vendor pub/static pub/media app/etc -type d -exec chmod g+ws {} +
chown -R :${www_data_user_id} .
WEB_STARTUP
chmod +x config/appdata/startup.sh

mkdir -p config/setup/init/
cat << MAGENTO_INIT > config/setup/init/config-magento.sql
update core_config_data set value = 'http://${site_domain}/' where path like '%base_url%' and scope_id = 0;
DELETE FROM core_config_data WHERE path='web/cookie/cookie_domain';
DELETE from core_config_data where path like '%dev/debug/temp%';
DELETE from core_config_data where path like '%dev/restrict%';

-- add admin user

SET @SALT = "xxxxxxxx";
SET @USER = "${backend_user}";
SET @PASS = '${backend_password}';
SET @EMAIL = '${backend_email}';
SET @HPASS = CONCAT(SHA2(concat(@SALT,@PASS), 256), concat(':', @SALT, ':1')); 
  -- CONCAT(SHA2(CONCAT( @SALT , @PASS), 256 ), CONCAT(":", @SALT, ":1" ));
-- SELECT @EXTRA := MAX(extra) FROM admin_user WHERE extra IS NOT NULL;
SET @EXTRA = 'null';

DELETE FROM admin_user where username = @USER;

INSERT INTO admin_user (firstname,lastname,email,username,password,created,lognum,reload_acl_flag,is_active,extra,rp_token_created_at)
VALUES (@USER,@USER,@EMAIL,@USER, @HPASS,NOW(),0,0,1,@EXTRA,NOW());

INSERT INTO authorization_role (parent_id,tree_level,sort_order,role_type,user_id,user_type,role_name)
VALUES (1,2,0,'U',(SELECT user_id FROM admin_user WHERE username = @USER), 2, @USER);
MAGENTO_INIT

# create directory 
mkdir system

# create binaries

mkdir bin
cat << 'RUN' > bin/run.sh
docker run --rm -w /there \
  -v $(dirname $0)/../auth.json:/root/.composer/auth.json \
  -v $(dirname $0)/..:/there \
  php:${php_version}-apache \
  "\$@"
RUN

cat << RUN > bin/inc.sh
#!/usr/bin/env bash
docker-compose run --rm -w /tools ${web_host} "\$@"
RUN

cat << RUN > bin/app
#!/usr/bin/env bash
single=\$@
docker-compose exec -w /magento ${web_host} bash -c "\$single"
RUN

cat << RUN > bin/magento
#!/usr/bin/env bash
docker-compose exec -w /magento ${web_host} ./bin/magento "\$@"
RUN

cat << COMPOSER > bin/composer
#!/usr/bin/env bash
docker-compose run --rm -w /magento ${web_host} composer "\$@"
COMPOSER

cat << REDIS > bin/redis
#!/usr/bin/env bash
docker-compose exec ${redis_host} redis-cli "\$@"
REDIS

cat << RUN > bin/mysql
#!/usr/bin/env bash
source \$(dirname \$0)/../.env
docker-compose exec ${mysql_host} mysql \
  -u${mysql_user} -p${mysql_password} ${mysql_database} \
  -A "\$@"
RUN

cat << RUN > bin/mysqldump
#!/usr/bin/env bash
source \$(dirname \$0)/../.env
docker-compose exec ${mysql_host} mysqldump \
  -u${mysql_user} -p${mysql_password} ${mysql_database} \
  "\$@" 2>/dev/null
RUN


declare -a tools
tools=("redis" "composer", "mysql", "mysqldump", "magento", "app")
declare -A tools_redis
tools_redis=(
  ["info-keyspace"]="info keyspace"
  ["flushall"]="flushall"
  ["monitor"]="monitor"
  ["ping"]="ping"
  ["flush-page-cache"]="-n ${redis_db_page_cache} FLUSHDB"
  ["flush-session-save"]="-n ${redis_db_session_save} FLUSHDB"
  ["flush-backend"]="-n ${redis_db_backend} FLUSHDB"
)
declare -A tools_composer
tools_composer=(
  ["magento-update-plugin"]="magento-update-plugin"
  ["update"]="update"
  ["upgrade"]="upgrade"
  ["run"]="run"
  ["list"]="list"
  ["install"]="install"
)
declare -A tools_mysql
tools_mysql=(
  ["show-tables"]='-e "show tables"'
)
declare -A tools_mysqldump
tools_mysqldump=(
  ["no-data"]='--no-data'
  ["no-create-info"]='--no-create-info'
)
declare -A tools_magento
tools_magento=(
  ["deploy-static"]='setup:static-content:deploy -f'
  ["developer-mode"]='deploy:mode:set developer -s'
  ["production-mode"]='deploy:mode:set production'
)
declare -A tools_app
tools_app=(
  ["clear-code-generated"]='rm -rf "/magento/generated/code/*"'
  ["clear-metadata-generated"]='rm -rf "/magento/generated/metadata/*"'
  ["clear-view-preprocessed"]='rm -rf "/magento/var/view_preprocessed/*"'
  ["clear-static"]='"rm -rf "/magento/pub/static/*""'
)

for tool in ${tools[@]}; do 
  eval 'keys=${!tools_'$tool'[@]}'
  for subtool in $keys; do
    eval 'command=${tools_'$tool'['$subtool']}'
cat << BIN_TOOL > bin/${tool}-${subtool}
#!/usr/bin/env bash
\$(dirname \$0)/${tool} ${command} "\${@}"
BIN_TOOL
  done
done

chmod +x bin/*


# build images
docker-compose build || (echo could not build images; exit 1) || exit 1

# Create magento project
if [ -f $(pwd)/system/composer.json ]; then
  echo "Magento project already created, skipping"
else
  # check images
  docker-compose run --rm ${web_host} php -r '@imagecreatefromjpeg();'  || (echo missing imagecreatefromjpeg in php; exit 1) || exit 1
  docker-compose run --rm ${web_host} php -r '@imageftbbox();'  || (echo missing imageftbbox in php; exit 1) || exit 1

  docker run --rm -v $(pwd)/system:/magento alpine:latest sh -c 'find /magento/ -maxdepth 1 | tail -n+2 | xargs rm -Rf'  || (echo could not cleanup magento directory; exit 1) || exit 1

  web_image=$(docker-compose build ${web_host} 2>&1 | tail -n1 | awk '{print $NF}')
  docker run --rm -ti --name create-magento-project \
    -v /home/${USER}/.composer:/root/.composer/ \
    -v $(pwd)/auth.json:/root/.composer/auth.json \
    -v $(pwd)/system:/magento \
    -w /magento \
    ${web_image} \
    composer \
    create-project \
    --repository-url=${magento_repository_url} \
    magento/${magento_distribution}:${magento_version} \
    --no-progress \
    --profile \
    --prefer-dist . \
     || (echo could not create magento project; exit 1) || exit 1

  # copy static .htaccess file
  cp -Rf system/pub/static config/${web_host}/filesystem/magento/pub/
fi
docker-compose up -d ${web_host} || (echo could not start server ${web_host}; exit 1) || exit 1

echo waiting ${mysql_host} to become available on port ${mysql_port}
while [ $(docker-compose ps | grep ${mysql_host} | grep Up | grep ${mysql_port} | wc -l) -eq 0 ]; do
  sleep 0.5s
done
sleep 1s

if [ ! -f $(pwd)/system/app/etc/env.php ]; then
echo Installing magento and setup connection to database, redis and elasticsearch
./bin/magento setup:install --cleanup-database \
  --base-url=http://${site_domain}/ \
  --db-host=${mysql_host} \
  --db-name=${mysql_database} \
  --db-user=${mysql_user} \
  --db-password=${mysql_password} \
  --admin-firstname=admin \
  --admin-lastname=admin \
  --admin-email=${backend_email} \
  --admin-user=${backend_user} \
  --admin-password=${backend_password} \
  --language=en_US \
  --currency=USD \
  --timezone=America/Chicago \
  --use-rewrites=1 \
  --cache-backend=redis \
  --cache-backend-redis-server=${redis_host} \
  --cache-backend-redis-db=${redis_db_backend} \
  --cache-backend-redis-port=${redis_port} \
  --cache-backend-redis-compress-data=1 \
  --page-cache=redis \
  --page-cache-redis-server=${redis_host} \
  --page-cache-redis-port=${redis_port} \
  --page-cache-redis-db=${redis_db_page_cache} \
  --page-cache-redis-compress-data=1 \
  --session-save=redis \
  --session-save-redis-host=${redis_host} \
  --session-save-redis-port=${redis_port} \
  --session-save-redis-persistent-id=PERSIS \
  --session-save-redis-db=${redis_db_session_save} \
  --session-save-redis-compression-threshold=2048 \
  --session-save-redis-log-level=7\
  --session-save-redis-max-concurrency=6 \
  --session-save-redis-break-after-frontend=5 \
  --session-save-redis-break-after-adminhtml=30 \
  --session-save-redis-first-lifetime=600 \
  --session-save-redis-bot-first-lifetime=60 \
  --session-save-redis-bot-lifetime=7200 \
  --session-save-redis-disable-locking=0 \
  --session-save-redis-min-lifetime=60 \
  --session-save-redis-max-lifetime=2592000 \
  --search-engine=elasticsearch7 \
  --elasticsearch-host=${elast_host} \
  --elasticsearch-port=9200 \
  --elasticsearch-enable-auth=0 \
  --elasticsearch-index-prefix=magento2 \
   || (echo could not setup magento install; exit 1) || exit 1

  ./bin/magento deploy:mode:set developer  || (echo could not setup developer mode in php; exit 1) || exit 1

  ./bin/magento module:disable Magento_TwoFactorAuth 
  ./bin/magento cache:flush 
else
  echo 'magento is already installed'
fi

admin_path=$(cat system/app/etc/env.php | egrep -o "admin_[^']*")

echo '# System information' > README.md
(
echo - Magento system http://${site_domain}/${admin_path} user: ${backend_user} password: ${backend_password}
echo - Phpmyadmin http://localhost:${pma_port} user:${pma_user} password: ${pma_password}
echo - Mailserver http://localhost:${mailserver_port}
) | tee -a README.md