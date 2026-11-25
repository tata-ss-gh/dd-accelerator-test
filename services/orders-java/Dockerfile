FROM eclipse-temurin:21-jdk AS build
WORKDIR /src
COPY . .
RUN ./mvnw -q -B -DskipTests package
ADD https://dtdg.co/latest-java-tracer /agents/dd-java-agent.jar

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /src/target/orders-0.0.1-SNAPSHOT.jar app.jar
COPY --from=build /agents /agents
ENV DD_SERVICE=orders DD_LOGS_INJECTION=true DD_RUNTIME_METRICS_ENABLED=true DD_TRACE_OTEL_ENABLED=true
EXPOSE 8002
CMD ["java", "-Xmx256m", "-javaagent:/agents/dd-java-agent.jar", \
     "-Dlogging.file.name=/var/log/shoplite/orders.json", "-jar", "app.jar"]
