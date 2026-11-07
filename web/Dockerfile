FROM nginx:1.27-alpine

# Official nginx image /etc/nginx/templates ke .template files par envsubst chalata hai
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80
