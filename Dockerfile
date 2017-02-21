FROM resin/armv7hf-debian-qemu
#FROM armbuild/debian:jessie

RUN [ "cross-build-start" ]

# persistent / runtime deps
ENV PHPIZE_DEPS \
		autoconf \
		file \
		g++ \
		gcc \
		libc-dev \
		make \
		pkg-config \
		re2c
RUN apt-get update && apt-get install -y \
		$PHPIZE_DEPS \
		ca-certificates \
		curl \
		libedit2 \
		libsqlite3-0 \
		libxml2 \
		xz-utils \
	--no-install-recommends && rm -r /var/lib/apt/lists/*

ENV PHP_INI_DIR /usr/local/etc/php
RUN mkdir -p $PHP_INI_DIR/conf.d

RUN apt-get update && apt-get install -y apache2-bin apache2.2-common --no-install-recommends && rm -rf /var/lib/apt/lists/*

ENV APACHE_CONFDIR /etc/apache2
ENV APACHE_ENVVARS $APACHE_CONFDIR/envvars

RUN set -ex \
	\
# generically convert lines like
#   export APACHE_RUN_USER=www-data
# into
#   : ${APACHE_RUN_USER:=www-data}
#   export APACHE_RUN_USER
# so that they can be overridden at runtime ("-e APACHE_RUN_USER=...")
	&& sed -ri 's/^export ([^=]+)=(.*)$/: ${\1:=\2}\nexport \1/' "$APACHE_ENVVARS" \
	\
# setup directories and permissions
	&& . "$APACHE_ENVVARS" \
	&& for dir in \
		"$APACHE_LOCK_DIR" \
		"$APACHE_RUN_DIR" \
		"$APACHE_LOG_DIR" \
		/var/www/html \
	; do \
		rm -rvf "$dir" \
		&& mkdir -p "$dir" \
		&& chown -R "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$dir"; \
	done

# Apache + PHP requires preforking Apache for best results
RUN a2dismod mpm_event && a2enmod mpm_prefork

# logs should go to stdout / stderr
RUN set -ex \
	&& . "$APACHE_ENVVARS" \
	&& ln -sfT /dev/stderr "$APACHE_LOG_DIR/error.log" \
	&& ln -sfT /dev/stdout "$APACHE_LOG_DIR/access.log" \
	&& ln -sfT /dev/stdout "$APACHE_LOG_DIR/other_vhosts_access.log"

# PHP files should be handled by PHP, and should be preferred over any other file type
RUN { \
		echo '<FilesMatch \.php$>'; \
		echo '\tSetHandler application/x-httpd-php'; \
		echo '</FilesMatch>'; \
		echo; \
		echo 'DirectoryIndex disabled'; \
		echo 'DirectoryIndex index.php index.html'; \
		echo; \
		echo '<Directory /var/www/>'; \
		echo '\tOptions -Indexes'; \
		echo '\tAllowOverride All'; \
		echo '</Directory>'; \
	} | tee "$APACHE_CONFDIR/conf-available/docker-php.conf" \
	&& a2enconf docker-php

ENV PHP_EXTRA_BUILD_DEPS apache2-dev
ENV PHP_EXTRA_CONFIGURE_ARGS --with-apxs2

ENV GPG_KEYS 1A4E8B7277C42E53DBA9C7B9BCAA30EA9C0D5763

ENV PHP_VERSION 7.0.11
ENV PHP_FILENAME php-7.0.11.tar.xz
ENV PHP_SHA256 d4cccea8da1d27c11b89386f8b8e95692ad3356610d571253d00ca67d524c735

RUN set -xe \
	&& cd /usr/src \
	&& curl -fSL "https://secure.php.net/get/$PHP_FILENAME/from/this/mirror" -o php.tar.xz \
	&& echo "$PHP_SHA256 *php.tar.xz" | sha256sum -c - \
	&& curl -fSL "https://secure.php.net/get/$PHP_FILENAME.asc/from/this/mirror" -o php.tar.xz.asc \
	&& export GNUPGHOME="$(mktemp -d)" \
	&& for key in $GPG_KEYS; do \
		gpg --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
	done \
	&& gpg --batch --verify php.tar.xz.asc php.tar.xz \
	&& rm -r "$GNUPGHOME"

COPY docker-php-source /usr/local/bin/

RUN set -xe \
	&& buildDeps=" \
		$PHP_EXTRA_BUILD_DEPS \
		libcurl4-openssl-dev \
		libedit-dev \
		libsqlite3-dev \
		libssl-dev \
		libxml2-dev \
	" \
	&& apt-get update && apt-get install -y $buildDeps --no-install-recommends && rm -rf /var/lib/apt/lists/* \
	\
	&& docker-php-source extract \
	&& cd /usr/src/php \
	&& ./configure \
		--with-config-file-path="$PHP_INI_DIR" \
		--with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
		\
		--disable-cgi \
		\
# --enable-ftp is included here because ftp_ssl_connect() needs ftp to be compiled statically (see https://github.com/docker-library/php/issues/236)
		--enable-ftp \
# --enable-mbstring is included here because otherwise there's no way to get pecl to use it properly (see https://github.com/docker-library/php/issues/195)
		--enable-mbstring \
# --enable-mysqlnd is included here because it's harder to compile after the fact than extensions are (since it's a plugin for several extensions, not an extension in itself)
		--enable-mysqlnd \
		\
		--with-curl \
		--with-libedit \
		--with-openssl \
		--with-zlib \
		\
		$PHP_EXTRA_CONFIGURE_ARGS \
	&& make -j"$(nproc)" \
	&& make install \
	&& { find /usr/local/bin /usr/local/sbin -type f -executable -exec strip --strip-all '{}' + || true; } \
	&& make clean \
	&& docker-php-source delete \
	\
	&& apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false $buildDeps

COPY docker-php-ext-* /usr/local/bin/

COPY apache2-foreground /usr/local/bin/

RUN apt-get update && apt-get install -y \
        libfreetype6-dev \
        libjpeg62-turbo-dev \
        libmcrypt-dev \
        libpng12-dev \
        libxml2-dev \
        libbz2-dev \
    && docker-php-ext-install mysqli pdo pdo_mysql soap exif bz2 \
    && docker-php-ext-install -j$(nproc) iconv mcrypt \
    && docker-php-ext-configure gd --with-freetype-dir=/usr/include/ --with-jpeg-dir=/usr/include/ \
    && docker-php-ext-install -j$(nproc) gd

# Install opcache
RUN docker-php-ext-install opcache

# Hide errors
RUN echo "display_errors=off" > /usr/local/etc/php/conf.d/errors.ini
RUN echo "log_errors=on" >> /usr/local/etc/php/conf.d/errors.ini

# Install APCu
RUN pecl install apcu
RUN echo "extension=apcu.so" > /usr/local/etc/php/conf.d/apcu.ini
RUN echo "apc.enable_cli = On" >> /usr/local/etc/php/conf.d/apcu.ini

RUN a2enmod rewrite

# Install SSMTP
RUN apt-get install -y ssmtp
RUN echo 'sendmail_path = "/usr/sbin/ssmtp -t"' > /usr/local/etc/php/conf.d/mail.ini

# Set the time zone to the local time zone
RUN echo "Europe/Berlin" > /etc/timezone && dpkg-reconfigure --frontend noninteractive tzdata
RUN echo "date.timezone = Europe/Berlin" > /usr/local/etc/php/conf.d/timezone.ini

# PHP Typo3 Settings
RUN echo "always_populate_raw_post_data = -1" > /usr/local/etc/php/conf.d/typo3.ini
RUN echo "max_execution_time = 240" >> /usr/local/etc/php/conf.d/typo3.ini
RUN echo "max_input_vars = 1500" >> /usr/local/etc/php/conf.d/typo3.ini
RUN docker-php-ext-install zip
RUN apt-get install -y graphicsmagick

# INSTALL curl
RUN apt-get install -y curl

# Register the COMPOSER_HOME environment variable
ENV COMPOSER_HOME /composer

# Add global binary directory to PATH and make sure to re-export it
ENV PATH /composer/vendor/bin:$PATH

# Allow Composer to be run as root
ENV COMPOSER_ALLOW_SUPERUSER 1

# Setup the Composer installer
RUN curl -o /tmp/composer-setup.php https://getcomposer.org/installer \
  && curl -o /tmp/composer-setup.sig https://composer.github.io/installer.sig \
  && php -r "if (hash('SHA384', file_get_contents('/tmp/composer-setup.php')) !== trim(file_get_contents('/tmp/composer-setup.sig'))) { unlink('/tmp/composer-setup.php'); echo 'Invalid installer' . PHP_EOL; exit(1); }"

# Install Composer
RUN php /tmp/composer-setup.php --no-ansi --install-dir=/usr/local/bin --filename=composer && rm -rf /tmp/composer-setup.php

RUN apt-get install -y git unzip

# copy ssh key and autostart keychain on login
RUN mkdir /root/.ssh
RUN chmod 644 /root/.ssh
RUN apt-get install -y keychain
RUN echo '\nif [ -e "/ssh/id_rsa.pub" ]; then' >> /root/.bashrc
RUN echo '    cp /ssh/id_rsa.pub ~/.ssh/id_rsa.pub' >> /root/.bashrc
RUN echo '    chmod 644 /root/.ssh/id_rsa.pub' >> /root/.bashrc
RUN echo 'fi' >> /root/.bashrc
RUN echo '\nif [ -e "/ssh/id_rsa" ]; then' >> /root/.bashrc
RUN echo '    cp /ssh/id_rsa ~/.ssh/id_rsa' >> /root/.bashrc
RUN echo '    chmod 600 ~/.ssh/id_rsa' >> /root/.bashrc
RUN echo '    eval $(keychain --eval id_rsa)' >> /root/.bashrc
RUN echo 'fi' >> /root/.bashrc

# set term
RUN echo '\nexport TERM=xterm' >> /root/.bashrc

# add phpinfo file
ADD index.php /var/www/html/index.php

RUN [ "cross-build-end" ]

WORKDIR /var/www/html

EXPOSE 80
CMD ["apache2-foreground"]
