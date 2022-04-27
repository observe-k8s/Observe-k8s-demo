FROM golang:1.17-alpine as builder
WORKDIR $GOPATH/src/go.k6.io/k6
ADD . .
RUN apk --no-cache add git
# RUN CGO_ENABLED=0 go install -a -trimpath -ldflags "-s -w -X go.k6.io/k6/lib/consts.VersionDetails=$(date -u +"%FT%T%z")/$(git describe --always --long --dirty)"
RUN go install -trimpath go.k6.io/xk6/cmd/xk6@latest
RUN xk6 build v0.35.0 --with github.com/k6io/xk6-distributed-tracing@latest --with github.com/grafana/xk6-output-prometheus-remote@latest

RUN cp k6 $GOPATH/bin/k6

# COPY ./tests ./tests

FROM alpine:3.13
RUN apk add --no-cache ca-certificates && \
    adduser -D -u 12345 -g 12345 k6
COPY --from=builder /go/bin/k6 /usr/bin/k6

USER 12345
ARG VUS="10"
ARG DURATION="24h"

COPY --chown=root:root ./loadgenerator.js ./loadgenerator.js
ENTRYPOINT ["k6","run","-o", "output-prometheus-remote" ,"/loadgenerator.js"]