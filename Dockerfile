FROM entplus.jfrog.io/art-docker/node:14.19.0-alpine3.15

ARG SONAR_VERSION=4.6.2.2472
ARG SONAR_DOWNLOAD_PATH=https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_VERSION}-linux.zip
ARG SONAR_BIN_PATH=/opt/sonar-scanner-${SONAR_VERSION}-linux/bin
ARG SSH_CONFIG=/etc/ssh/ssh_config

RUN apk add --no-cache bash python3 coreutils grep curl openssl jq git docker docker-compose openssh-client unzip openjdk11 \
    && curl -fL https://getcli.jfrog.io | sh \
    && curl -Lo /tmp/sonar-scanner-cli-${SONAR_VERSION}-linux.zip ${SONAR_DOWNLOAD_PATH} \
    && unzip -d /opt/ /tmp/sonar-scanner-cli-${SONAR_VERSION}-linux.zip \
    && rm -f /tmp/sonar-scanner-cli-${SONAR_VERSION}-linux.zip \
    && apk del unzip \
    && sed -i 's/use_embedded_jre=true/use_embedded_jre=false/' ${SONAR_BIN_PATH}/sonar-scanner \
    && ln -s ${SONAR_BIN_PATH}/sonar-scanner /usr/local/bin/sonar-scanner \
    && echo "Host git.jfrog.info" >> ${SSH_CONFIG} \
    && echo "  HostkeyAlgorithms +ssh-rsa" >> ${SSH_CONFIG} \
    && echo "  PubkeyAcceptedAlgorithms +ssh-rsa" >> ${SSH_CONFIG} \
    && mkdir ~/.ssh

COPY run-sonar-scanner.sh /usr/local/bin/run-sonar-scanner.sh

ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk
