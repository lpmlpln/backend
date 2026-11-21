# Build from the workspace root:
#   docker build -f mealplanner-api/Dockerfile -t mealplanner-api .
FROM swift:6.4.3-noble AS build
WORKDIR /build
COPY mealplanner-api/Package.swift mealplanner-api/Package.resolved ./
COPY mealplanner-api/Sources ./Sources
COPY mealplanner-api/Tests ./Tests
COPY mealplanner-core /mealplanner-core
RUN swift build -c release --static-swift-stdlib

FROM swift:6.4.3-noble-slim
RUN apt-get update && apt-get install -y \
    ca-certificates tzdata libssl3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/.build/release/App /app/App
EXPOSE 8080
USER 1000
CMD ["/app/App", "serve", "--hostname", "0.0.0.0", "--port", "8080"]
