# Local compatibility build based on NorskHelsenett/ollama-metrics.
FROM golang:1.24-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY main.go .

RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' -o ollama-metrics .

FROM scratch

COPY --from=builder /app/ollama-metrics /ollama-metrics

ENTRYPOINT ["/ollama-metrics"]
