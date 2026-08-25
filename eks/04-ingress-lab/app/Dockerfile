FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod ./
COPY *.go ./
# go mod tidy resuelve y fija dependencias dentro del build.
# Evita necesitar go.sum en el host ni tener Go instalado en CloudShell.
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /identity-api .

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /identity-api /identity-api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/identity-api"]
