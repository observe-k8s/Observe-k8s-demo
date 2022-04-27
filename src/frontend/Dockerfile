FROM golang:1.16.12 as builder
WORKDIR /build/src

COPY . .
ENV GOPROXY https://goproxy.cn
RUN go mod tidy
RUN go mod download
RUN go build -tags netgo -o main

FROM ubuntu as release
RUN apt-get update
RUN apt-get install wget -y
WORKDIR /frontend
COPY --from=builder /build/src/main /frontend/server
COPY ./templates ./templates
COPY ./static ./static
EXPOSE 8080
ENTRYPOINT ["/frontend/server"]