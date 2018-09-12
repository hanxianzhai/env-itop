FROM php:7.1-fpm

LABEL maintainer="hanxianzhai <hanxianzhai@gmail.com>"

ENV NGINX_VERSION 1.15.3-1~stretch
ENV NJS_VERSION   1.15.3.0.2.3-1~stretch

RUN set -x \
	&&echo "deb http://mirrors.aliyun.com/debian stretch main" > /etc/apt/sources.list \
	&&echo "deb http://mirrors.aliyun.com/debian-security stretch/updates main" >> /etc/apt/sources.list \
	&&echo "deb http://mirrors.aliyun.com/debian stretch-updates main" >> /etc/apt/sources.list

RUN set -x \
	&& apt-get update \
	&& apt-get upgrade \
	--no-install-recommends --no-install-suggests -y \
	&& apt-get install --no-install-recommends --no-install-suggests -y gnupg1 apt-transport-https ca-certificates \
	&& \
	NGINX_GPGKEY=573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62; \
	found=''; \
	for server in \
		ha.pool.sks-keyservers.net \
		hkp://keyserver.ubuntu.com:80 \
		hkp://p80.pool.sks-keyservers.net:80 \
		pgp.mit.edu \
	; do \
		echo "Fetching GPG key $NGINX_GPGKEY from $server"; \
		apt-key adv --keyserver "$server" --keyserver-options timeout=10 --recv-keys "$NGINX_GPGKEY" && found=yes && break; \
	done; \
	test -z "$found" && echo >&2 "error: failed to fetch GPG key $NGINX_GPGKEY" && exit 1; \
	apt-get remove --purge --auto-remove -y gnupg1 && rm -rf /var/lib/apt/lists/* \
	&& dpkgArch="$(dpkg --print-architecture)" \
	&& nginxPackages=" \
		nginx=${NGINX_VERSION} \
		nginx-module-xslt=${NGINX_VERSION} \
		nginx-module-geoip=${NGINX_VERSION} \
		nginx-module-image-filter=${NGINX_VERSION} \
		nginx-module-njs=${NJS_VERSION} \
	" \
	&& case "$dpkgArch" in \
		amd64|i386) \
# arches officialy built by upstream
			echo "deb https://nginx.org/packages/mainline/debian/ stretch nginx" >> /etc/apt/sources.list.d/nginx.list \
			&& apt-get update \
			;; \
		*) \
# we're on an architecture upstream doesn't officially build for
# let's build binaries from the published source packages
			echo "deb-src https://nginx.org/packages/mainline/debian/ stretch nginx" >> /etc/apt/sources.list.d/nginx.list \
			\
# new directory for storing sources and .deb files
			&& tempDir="$(mktemp -d)" \
			&& chmod 777 "$tempDir" \
# (777 to ensure APT's "_apt" user can access it too)
			\
# save list of currently-installed packages so build dependencies can be cleanly removed later
			&& savedAptMark="$(apt-mark showmanual)" \
			\
# build .deb files from upstream's source packages (which are verified by apt-get)
			&& apt-get update \
			&& apt-get build-dep -y $nginxPackages \
			&& ( \
				cd "$tempDir" \
				&& DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" \
					apt-get source --compile $nginxPackages \
			) \
# we don't remove APT lists here because they get re-downloaded and removed later
			\
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
# (which is done after we install the built packages so we don't have to redownload any overlapping dependencies)
			&& apt-mark showmanual | xargs apt-mark auto > /dev/null \
			&& { [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; } \
			\
# create a temporary local APT repo to install from (so that dependency resolution can be handled by APT, as it should be)
			&& ls -lAFh "$tempDir" \
			&& ( cd "$tempDir" && dpkg-scanpackages . > Packages ) \
			&& grep '^Package: ' "$tempDir/Packages" \
			&& echo "deb [ trusted=yes ] file://$tempDir ./" > /etc/apt/sources.list.d/temp.list \
# work around the following APT issue by using "Acquire::GzipIndexes=false" (overriding "/etc/apt/apt.conf.d/docker-gzip-indexes")
#   Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
#   ...
#   E: Failed to fetch store:/var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages  Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
			&& apt-get -o Acquire::GzipIndexes=false update \
			;; \
	esac \
	\
	&& apt-get install --no-install-recommends --no-install-suggests -y \
						$nginxPackages \
						gettext-base \
	&& apt-get remove --purge --auto-remove -y apt-transport-https ca-certificates && rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/nginx.list \
	\
# if we have leftovers from building, let's purge them (including extra, unnecessary build deps)
	&& if [ -n "$tempDir" ]; then \
		apt-get purge -y --auto-remove \
		&& rm -rf "$tempDir" /etc/apt/sources.list.d/temp.list; \
	fi

# forward request and error logs to docker log collector
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
	&& ln -sf /dev/stderr /var/log/nginx/error.log

# install the PHP extensions we need
RUN set -ex \
	&&apt-get update \
	&&apt-get install -y --no-install-recommends --no-install-suggests \
		graphviz \
		mariadb-client \
		libfreetype6-dev \
		libjpeg-dev \
		libldap2-dev \
		libmcrypt-dev \
		libpng-dev \
		libxml2-dev \
		unzip \
		zlib1g-dev \
		libkrb5-dev \
		libc-client2007e-dev \
		libxslt1-dev \
		supervisor \
	&&docker-php-ext-configure imap --with-kerberos --with-imap-ssl \
	&&docker-php-ext-install \
		gd \
		ldap \
		mcrypt \
		mysqli \
		soap \
		zip \
		imap \
		calendar \
		exif \
		sockets \
		xsl \
	&& apt-get remove -y \
		libfreetype6-dev \
		libjpeg-dev \
		libldap2-dev \
		libpng-dev \
		libxml2-dev \
		zlib1g-dev \
		libxslt1-dev \
	&& apt-get purge -y --auto-remove \
	&& rm -rf /var/lib/apt/lists/*

RUN set -ex \
	&& cd /usr/local/etc \
	&& rm -f php-fpm.d/docker.conf php-fpm.d/zz-docker.conf \
	&& { \
		echo '[global]'; \
		echo 'error_log = /proc/self/fd/2'; \
		echo; \
		echo '[www]'; \
		echo '; if we send this to /proc/self/fd/1, it never appears'; \
		echo 'access.log = /proc/self/fd/2'; \
		echo; \
		echo 'clear_env = no'; \
		echo; \
		echo '; Ensure worker stdout and stderr are sent to the main error log.'; \
		echo 'catch_workers_output = yes'; \
	} | tee php-fpm.d/docker.conf \
	&& { \
		echo '[global]'; \
		echo 'daemonize = off'; \
		echo 'pid = /var/run/php-fpm.pid'; \
		echo; \
		echo '[www]'; \
		echo 'listen = /dev/shm/php-fpm.sock'; \
		echo 'listen.owner = www-data'; \
		echo 'listen.group = www-data'; \
		echo 'listen.mode = 0660'; \
	} | tee php-fpm.d/zz-docker.conf

RUN mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak \
	&& mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
	\

COPY php.ini /usr/local/etc/php/
COPY conf.d/* /usr/local/etc/php/conf.d/
COPY nginx.conf /etc/nginx/nginx.conf
COPY itop-nginx.conf /etc/nginx/conf.d/
COPY supervisord_fpm.conf /etc/supervisor/conf.d/
COPY supervisord_nginx.conf /etc/supervisor/conf.d/

VOLUME "/var/www/html"

EXPOSE 80 443

STOPSIGNAL SIGTERM

CMD ["/usr/bin/supervisord","-n","-c","/etc/supervisor/supervisord.conf"]

# ENTRYPOINT ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisord/supervisord.conf"]