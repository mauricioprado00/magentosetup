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

extensions_already_included="
hash
libxml
"


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
    web0:
        build: config/web0
        container_name: web0
        ports:
          - "80:80"
          - "443:443"
          - "32823:22"
#        volumes:
#        - $(pwd)/config/web0/filesystem/magento/env.php:/magento/app/etc/env.php
        volumes_from:
        - appdata
        - magentodata
        depends_on:
        - mysql0
        - redis0
        - elast0
        links:
        - "mysql0:mysql0"
        - "redis0:redis0"
        - "elast0:elast0"
    composer:
        build: config/composer
        container_name: composer
        volumes:
          - /home/${USER}/.composer:/root/.composer/
        volumes_from:
        - appdata
    appdata:
        image: alpine:latest
        volumes:
          - $(pwd)/system:/magento:cached
          - $(pwd)/bin:/tools
          - $(pwd)/auth.json:/root/.composer/auth.json
    magentodata:
        image: alpine:latest
        volumes:
          - $(pwd)/config/appdata/startup.sh:/startup.sh
          - $(pwd)/config/web0/filesystem/magento/var/:/magento/var/
          - $(pwd)/config/web0/filesystem/etc/apache2/sites-available/000-default.conf:/etc/apache2/sites-available/000-default.conf
          - $(pwd)/config/web0/filesystem/magento/generated/:/magento/generated/
          - $(pwd)/config/web0/filesystem/magento/pub/static/:/magento/pub/static/
          - $(pwd)/config/web0/filesystem/magento/media/catalog:/magento/pub/media/catalog
          - $(pwd)/config/web0/filesystem/magento/media/wysiwyg:/magento/pub/media/wysiwyg
        command: /bin/sh /startup.sh
    mailserver:
      image: reachfive/fake-smtp-server
      ports:
          - "1080:1080"
    mysql0:
      image: mysql:${mysqldb_version}
      environment:
        MYSQL_ROOT_PASSWORD: root
        MYSQL_DATABASE: magento
        MYSQL_USER: maguser
        MYSQL_PASSWORD: magpass
      volumes:
        - ./data/:/data/
        #- $(pwd)/config/setup/init/config-magento.sql:/docker-entrypoint-initdb.d/02-init.sql
    elast0:
      image: elasticsearch:${elastic_version}
      environment:
        - "discovery.type=single-node"
    phpmyadmin:
        container_name: phpmyadmin
        image: phpmyadmin/phpmyadmin:latest
        environment:
          - MYSQL_ROOT_PASSWORD=root
          - PMA_USER=root
          - PMA_PASSWORD=root
        ports:
          - "8080:80"
        links:
          - mysql0:db
        depends_on:
          - mysql0
    redis0:
      image: redis:latest
      ports:
        - "6379:6379"
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

mkdir -p config/composer/
printf '%s' "$extensions_already_included" > .extensions_already_included
docker run --rm php:${php_version}-alpine php -m | grep -v '\[' | filter-list | grep -v '^$' > .extensions_already_included
install_dependencies=$(printf '%s\n' ${system_dep} | filter-list | sed 's#^#RUN apk add #g')
#install_extensions=$(printf '%s\n' ${extensions} | grep -v zip | grep -vFx -f .extensions_already_included | sed 's#^#RUN apk add php-#g')
install_extensions=$(
  install_extensions_string 'apk add php-' "$(printf '%s\n' ${extensions} | \
  grep -v zip | \
  grep -vFx -f .extensions_already_included)" | \
  grep -v configure
)

cat << DOCKERFILE > config/composer/Dockerfile
FROM php:${php_version}-alpine

RUN apk add zip zlib-dev
${install_dependencies}

RUN cp /usr/local/etc/php/php.ini-development  /usr/local/etc/php/php.ini
RUN sed -i 's#memory_limit.*#memory_limit=-1#g' /usr/local/etc/php/php.ini
RUN cd /usr/local/bin/ && \
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
    php composer-setup.php && \
    php -r "unlink('composer-setup.php');" && \
    ln -s composer.phar composer && \
    composer self-update --1

${install_extensions}

RUN cp /usr/lib/php7/modules/* /usr/local/lib/php/extensions/\$(ls /usr/local/lib/php/extensions/)
RUN cp /etc/php7/conf.d/* /usr/local/etc/php/conf.d
RUN apk add zip zlib-dev libzip libzip-dev
RUN docker-php-ext-install zip
RUN composer global require hirak/prestissimo

DOCKERFILE

# create Dockerfile for web container
install_extensions=$(
  install_extensions_string 'docker-php-ext-install ' "$(printf '%s\n' ${extensions} | \
  grep -vFx -f .extensions_already_included)"
)

printf '%s' "$extensions_already_included" > .extensions_already_included
docker run --rm php:${php_version}-apache php -m | grep -v '\[' | filter-list | grep -v '^$' > .extensions_already_included
install_dependencies=$(printf '%s\n' ${system_dep} | filter-list | sed 's#^#RUN apt-get install -y #g')
#install_extensions=$(printf '%s\n' ${extensions} | grep -vFx -f .extensions_already_included | sed 's#^#RUN docker-php-ext-install #g')
mkdir -p config/web0/
cat << DOCKERFILE > config/web0/Dockerfile
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
mkdir -p config/web0/filesystem/etc/apache2/sites-available/
cat << APACHE_VIRTUALHOST > config/web0/filesystem/etc/apache2/sites-available/000-default.conf
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
mkdir -p config/web0/filesystem/magento/
cat << MAGENTO_ENV > config/web0/filesystem/magento/env.php
<?php
return [
    'backend' => [
        'frontName' => 'adminelbow'
    ],
    'crypt' => [
        'key' => 'c4ee26a235f98b8afbb2412232e55628'
    ],
    'session' => [
        'save' => 'redis',
        'redis' => [
            'host' => 'redis0',
            'port' => '6379',
            'password' => '',
            'timeout' => '2.5',
            'persistent_identifier' => '',
            'database' => '2',
            'compression_threshold' => '2048',
            'compression_library' => 'gzip',
            'log_level' => '3',
            'max_concurrency' => '6',
            'break_after_frontend' => '5',
            'break_after_adminhtml' => '30',
            'first_lifetime' => '600',
            'bot_first_lifetime' => '60',
            'bot_lifetime' => '7200',
            'disable_locking' => '0',
            'min_lifetime' => '60',
            'max_lifetime' => '2592000',
            'sentinel_master' => '',
            'sentinel_servers' => '',
            'sentinel_connect_retries' => '5',
            'sentinel_verify_master' => '0'
        ]
    ],
    'db' => [
        'table_prefix' => '',
        'connection' => [
            'default' => [
                'host' => 'mysql0',
                'dbname' => 'magento',
                'username' => 'root',
                'password' => 'root',
                'model' => 'mysql4',
                'engine' => 'innodb',
                'initStatements' => 'SET NAMES utf8;',
                'active' => '1'
            ]
        ]
    ],
    'resource' => [
        'default_setup' => [
            'connection' => 'default'
        ]
    ],
    'x-frame-options' => 'SAMEORIGIN',
    'MAGE_MODE' => 'developer',
    'cache_types' => [
        'config' => 1,
        'layout' => 1,
        'block_html' => 1,
        'collections' => 1,
        'reflection' => 1,
        'db_ddl' => 1,
        'eav' => 1,
        'customer_notification' => 1,
        'full_page' => 1,
        'config_integration' => 1,
        'config_integration_api' => 1,
        'translate' => 1,
        'config_webservice' => 1,
        'compiled_config' => 1,
        'vertex' => 1,
        'google_product' => 0
    ],
    'install' => [
        'date' => 'Sat, 29 Apr 2017 20:51:47 +0000'
    ],
    'downloadable_domains' => [
        'stage.elbowchocolates.com'
    ],
    'cache' => [
        'frontend' => [
            'default' => [
                'id_prefix' => '649_',
                'backend' => 'Cm_Cache_Backend_Redis',
                'backend_options' => [
                    'server' => 'redis0',
                    'database' => '0',
                    'port' => '6379',
                    'password' => '',
                    'compress_data' => '1',
                    'compression_lib' => ''
                ]
            ],
            'page_cache' => [
                'id_prefix' => '649_',
                'backend' => 'Cm_Cache_Backend_Redis',
                'backend_options' => [
                    'server' => 'redis0',
                    'database' => '1',
                    'port' => '6379',
                    'password' => '',
                    'compress_data' => '0',
                    'compression_lib' => ''
                ]
            ]
        ]
    ],
    'lock' => [
        'provider' => 'db',
        'config' => [
            'prefix' => ''
        ]
    ]
];
MAGENTO_ENV

mkdir -p config/web0/filesystem/magento/generated/
mkdir -p config/web0/filesystem/magento/log/
mkdir -p config/web0/filesystem/magento/media/catalog/
mkdir -p config/web0/filesystem/magento/media/wysiwyg/
mkdir -p config/web0/filesystem/magento/pub/static/
mkdir -p config/web0/filesystem/magento/var/
echo '*' \
  > config/web0/filesystem/magento/generated/.gitignore \
  > config/web0/filesystem/magento/log/.gitignore \
  > config/web0/filesystem/magento/media/catalog/.gitignore \
  > config/web0/filesystem/magento/media/wysiwyg/.gitignore \
  > config/web0/filesystem/magento/pub/static/.gitignore \
  > config/web0/filesystem/magento/var/.gitignore

cat << HTACCESSDENY > config/web0/filesystem/magento/generated/.htaccess
<IfVersion < 2.4>
    order allow,deny
    deny from all
</IfVersion>
<IfVersion >= 2.4>
    Require all denied
</IfVersion>


HTACCESSDENY


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
chown -R :www-data .
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
cat << RUN > bin/run.sh
docker run --rm -w /there -v $(pwd)/auth.json:/root/.composer/auth.json -v $(pwd):/there php:8-apache "\$@"
RUN

cat << RUN > bin/inc.sh
docker-compose run --rm -w /tools web0 "\$@"
RUN

cat << RUN > bin/app.sh
docker-compose exec -ti -w /magento web0 "\$@"
RUN

cat << RUN > bin/magento.sh
docker-compose exec -w /magento web0 ./bin/magento "\$@"
RUN

cat << COMPOSER > bin/composer.sh
docker-compose run --rm -w /magento composer composer "\$@"
COMPOSER


chmod +x bin/*.sh


# build images
docker-compose build || (echo could not build images; exit 1) || exit 1

# Create magento project
if [ -f $(pwd)/system/composer.json ]; then
  echo "Magento project already created, skipping"
else
  # check images
  docker-compose run --rm web0 php -r '@imagecreatefromjpeg();'  || (echo missing imagecreatefromjpeg in php; exit 1) || exit 1
  docker-compose run --rm web0 php -r '@imageftbbox();'  || (echo missing imageftbbox in php; exit 1) || exit 1

  docker run --rm -v $(pwd)/system:/magento alpine:latest bash -c 'rm -Rf /magento/*'

  ./bin/composer.sh create-project --repository-url=https://repo.magento.com/ magento/${magento_distribution}:${magento_version} --no-progress --profile --prefer-dist .

fi
docker-compose up -d web0 || (echo could not start server web0; exit 1) || exit 1

echo waiting mysql0 to be available on port 3306
while [ $(docker-compose ps | grep mysql0 | grep Up | grep 3306 | wc -l) -eq 0 ]; do
  sleep 0.5s
done
sleep 1s

./bin/magento.sh setup:install --cleanup-database \
  --base-url=http://${site_domain}/ \
  --db-host=mysql0 \
  --db-name=magento \
  --db-user=root \
  --db-password=root \
  --admin-firstname=admin \
  --admin-lastname=admin \
  --admin-email=${backend_email} \
  --admin-user=${backend_user} \
  --admin-password=${backend_password} \
  --language=en_US \
  --currency=USD \
  --timezone=America/Chicago \
  --use-rewrites=1 \
  --cache-backend-redis-server=redis0 \
  --cache-backend-redis-db=2 \
  --cache-backend-redis-port=6379 \
  --cache-backend-redis-compress-data=1 \
  --page-cache-redis-server=redis0 \
  --page-cache-redis-port=6379 \
  --page-cache-redis-db=3 \
  --page-cache-redis-compress-data=1 \
  --session-save-redis-host=redis0 \
  --session-save-redis-port=6379 \
  --session-save-redis-persistent-id=PERSIS \
  --session-save-redis-db=4 \
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
  --elasticsearch-host=elast0 \
  --elasticsearch-port=9200 \
  --elasticsearch-enable-auth=0 \
  --elasticsearch-index-prefix=magento2


./bin/magento.sh deploy:mode:set developer

./bin/magento.sh module:disable Magento_TwoFactorAuth
./bin/magento.sh cache:flush 