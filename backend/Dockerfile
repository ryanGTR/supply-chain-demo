# ─────── Stage 1: build the war ───────
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build

COPY pom.xml .
RUN mvn -B -q dependency:go-offline

COPY src ./src
RUN mvn -B -q clean package -DskipTests

# ─────── Stage 2: Open Liberty runtime ───────
FROM icr.io/appcafe/open-liberty:full-java21-openj9-ubi-minimal

COPY --chown=1001:0 src/main/liberty/config/server.xml /config/server.xml
COPY --chown=1001:0 --from=build /build/target/liberty-backend.war /config/apps/

EXPOSE 9080 9443
