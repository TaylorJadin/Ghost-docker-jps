FROM nginxproxy/nginx-proxy:alpine
RUN { \
      echo 'client_max_body_size 100m;'; \
    } > /etc/nginx/conf.d/custom.conf
