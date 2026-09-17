# Runtime do primeiro commit; AWB-security-JAAS usa InetAddress.addressCache.
FROM azul/zulu-openjdk:7@sha256:ba31b92fba2cfa84844e187d4d70343c5a0a1886f30131a66afc5908d81a0ca5

LABEL maintainer="docker-legacy"
LABEL description="Tomcat 7 + OpenJDK 7 (Azul Zulu) + Ant para monolito legado Java 7"

ENV JAVA_HOME=/usr/lib/jvm/zulu7-ca-amd64
ENV PATH=$JAVA_HOME/bin:$PATH

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    tar \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Apache Ant 1.9.x (ultima versao compativel com Java 7)
ENV ANT_VERSION=1.9.16
RUN curl -fsSLk "https://archive.apache.org/dist/ant/binaries/apache-ant-${ANT_VERSION}-bin.tar.gz" \
    | tar -xz -C /opt \
    && ln -s /opt/apache-ant-${ANT_VERSION} /opt/ant
ENV ANT_HOME=/opt/ant
ENV PATH=$ANT_HOME/bin:$PATH

# Tomcat 7
ENV CATALINA_HOME=/opt/tomcat
ENV TOMCAT_VERSION=7.0.109
ENV PATH=$CATALINA_HOME/bin:$PATH

RUN mkdir -p "$CATALINA_HOME" \
    && curl -fsSLk "https://archive.apache.org/dist/tomcat/tomcat-7/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" \
    | tar -xz --strip-components=1 -C "$CATALINA_HOME" \
    && chmod +x "$CATALINA_HOME/bin/"*.sh

# Remover apps default do Tomcat
RUN rm -rf "$CATALINA_HOME/webapps/ROOT" \
    && rm -rf "$CATALINA_HOME/webapps/examples" \
    && rm -rf "$CATALINA_HOME/webapps/docs" \
    && rm -rf "$CATALINA_HOME/webapps/manager" \
    && rm -rf "$CATALINA_HOME/webapps/host-manager"

ENV CATALINA_OPTS="-Xms512m -Xmx2048m -XX:PermSize=256m -XX:MaxPermSize=512m"

COPY conf/server.xml $CATALINA_HOME/conf/server.xml
COPY conf/application-tu.properties.example /opt/docker-templates/conf/application-tu.properties.example
COPY conf/ojdbc8.jar $CATALINA_HOME/lib/ojdbc8.jar
COPY conf/context.xml.example /opt/docker-templates/conf/context.xml.example
COPY conf/login-mock.xml /opt/docker-templates/conf/login-mock.xml
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
RUN sed -i 's/\r$//' /entrypoint.sh && bash -n /entrypoint.sh && chmod +x /entrypoint.sh
RUN sed -i 's/\r$//' /healthcheck.sh && bash -n /healthcheck.sh && chmod +x /healthcheck.sh

EXPOSE 8080

WORKDIR $CATALINA_HOME

ENTRYPOINT ["/entrypoint.sh"]
CMD ["catalina.sh", "run"]
