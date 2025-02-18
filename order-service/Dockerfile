FROM golang:1.18-alpine AS builder

WORKDIR /app

COPY go.mod ./
COPY go.sum ./

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o order-service .

FROM alpine:3.15

RUN apk --no-cache add ca-certificates

WORKDIR /root/

COPY --from=builder /app/order-service .

EXPOSE 8080

CMD ["./order-service"]