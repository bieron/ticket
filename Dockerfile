FROM alpine

WORKDIR /usr/lib/ticket
COPY . ./
RUN apk add --update git curl perl perl-app-cpanminus make gcc bash wget perl-dev libc-dev \
 && ./install \
 && apk del perl-app-cpanminus make gcc wget perl-dev libc-dev \
 && rm -r install cpanfile Dockerfile taskhandler ticket.conf /var/cache/apk/*
ENV PATH=$PATH:/usr/lib/ticket/scripts
