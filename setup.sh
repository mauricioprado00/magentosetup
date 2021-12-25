php_version=7.4
magento_distribution=project-community-edition
magento_version=2.4

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
        volumes:
        - ./config/web0/filesystem/magento/env.php:/magento/app/etc/env.php
        volumes_from:
        - appdata
        depends_on:
        - mysql0
        links:
        - "mysql0:mysql0"
    composer:
        build: config/composer
        container_name: composer
        volumes:
          - /home/${USER}/.composer-home:/root/.composer/
        volumes_from:
        - appdata
    appdata:
        image: alpine:latest
        volumes:
          - $(pwd)/system:/app:cached
          - $(pwd)/bin:/tools
          - $(pwd)/auth.json:/root/.composer/auth.json
    mysql0:
        image: mariadb:10
        container_name: mysql0
        ports:
          - "3306:3306"
        environment:
          - MYSQL_ROOT_PASSWORD=root
          - MYSQL_DATABASE=magento
        volumes:
          - db-data:/var/lib/mysql
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
volumes:
    db-data:
        external: false
EOF

function filter-list
{
  sed 's/#.*//g' | grep -v '^$'
}

# create Dockerfile for composer container
# use https://github.com/hirak/prestissimo
mkdir -p /home/${USER}/.composer-home
mkdir -p config/composer/
printf '%s' "$extensions_already_included" > .extensions_already_included
docker run --rm php:${php_version}-alpine php -m | grep -v '\[' | filter-list | grep -v '^$' > .extensions_already_included
install_dependencies=$(printf '%s\n' ${system_dep} | filter-list | sed 's#^#RUN apk add #g')
install_extensions=$(printf '%s\n' ${extensions} | grep -v zip | grep -vFx -f .extensions_already_included | sed 's#^#RUN apk add php-#g')
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
printf '%s' "$extensions_already_included" > .extensions_already_included
docker run --rm php:${php_version}-apache php -m | grep -v '\[' | filter-list | grep -v '^$' > .extensions_already_included
install_dependencies=$(printf '%s\n' ${system_dep} | filter-list | sed 's#^#RUN apt-get install -y #g')
install_extensions=$(printf '%s\n' ${extensions} | grep -vFx -f .extensions_already_included | sed 's#^#RUN docker-php-ext-install #g')
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

WORKDIR /magento
DOCKERFILE

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
docker-compose run --rm -w /app web0 "\$@"
RUN


cat << COMPOSER > bin/composer.sh
docker-compose run --rm -w /app composer composer "\$@"
COMPOSER


chmod +x bin/*.sh


# spin up server
docker-compose up -d --build

# Create magento project

./bin/composer.sh create-project --repository-url=https://repo.magento.com/ magento/${magento_distribution}:${magento_version} --no-progress --profile --prefer-dist .

