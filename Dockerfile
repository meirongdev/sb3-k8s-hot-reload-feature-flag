# Shared Dockerfile. Build with: docker build -f Dockerfile <module>/
# Each module's target/ must contain the Spring Boot repackaged fat jar.

FROM eclipse-temurin:25-jre
WORKDIR /app
# *.jar matches the repackaged fat jar; *.jar.original is left out by glob.
COPY target/*.jar /app/app.jar
ENTRYPOINT ["java", "-XX:+UseZGC", "-jar", "/app/app.jar"]
