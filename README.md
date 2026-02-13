# ReverseProxy + Search Engine (Elixir)

A Phoenix/Elixir application that combines:

- an L7 reverse proxy (dynamic routing, discovery, middleware, health checks)
- an in-process full-text search engine (Elasticsearch-like MVP)

## What is included

### Reverse proxy

- Dynamic router/service/endpoint state in ETS
- Docker label-based discovery
- Host + path-prefix routing
- Round-robin upstream selection
- Basic auth + request/response header middleware
- Health checks
- Admin dashboard (Phoenix LiveView)
- Prometheus-style metrics endpoint

### Search engine (MVP)

- JSON document CRUD with versioning
- Inverted index with sharding and local replicas
- Analyzer pipeline (tokenization, normalization, stopwords, stemming, synonyms)
- Query DSL: `term`, `match`, `phrase`, `bool`, `fuzzy`, `wildcard`, `range`
- BM25 relevance scoring with boosting
- Aggregations: `terms`, `range`, `histogram`, `date_histogram`, `count/sum/avg/min/max`
- Pagination: `from/size`, `search_after`

## Requirements

- macOS or Linux
- Nix (Determinate Nix works)

## Quick start

```bash
nix-shell
mix deps.get
mix phx.server
```

App endpoints:

- Home: `http://localhost:4000/`
- Admin dashboard: `http://localhost:4000/admin/dashboard`
- Metrics: `http://localhost:4000/metrics`
- Health: `http://localhost:4000/health`

## Reverse proxy discovery labels

Supported container labels:

- `proxy.enable=true`
- `proxy.rule=Host(api.example.com)`
- `proxy.rule=Host(api.example.com) && PathPrefix(/v1)`
- `proxy.port=4000`
- `proxy.path_prefix=/api`
- `proxy.tls=true`
- `proxy.health_path=/healthz`
- `proxy.auth.user=admin`
- `proxy.auth.pass=secret`
- `proxy.req_header.x-foo=bar`
- `proxy.resp_header.x-powered-by=reverse-proxy`

## Environment variables

- `PORT` (default `4000`)
- `HTTPS_PORT` (default `4443`)
- `SECRET_KEY_BASE` (required in `prod`)
- `PROXY_ADMIN_USER` (default `admin`)
- `PROXY_ADMIN_PASS` (default `admin`)
- `PROXY_ADMIN_IP_WHITELIST` (optional, comma-separated)
- `DOCKER_API_BASE` (default `http://localhost:2375`)
- `PROXY_TLS_CERT_PATH` (default `priv/certs/tls.crt`)
- `PROXY_TLS_KEY_PATH` (default `priv/certs/tls.key`)
- `PROXY_HEALTH_PATH` (default `/health`)

## Search API

Base path: `/api/v1/search`

- `PUT /indexes/:index`
- `DELETE /indexes/:index`
- `GET /indexes/:index`
- `PUT /indexes/:index/documents/:id`
- `GET /indexes/:index/documents/:id`
- `DELETE /indexes/:index/documents/:id`
- `POST /indexes/:index/_bulk`
- `POST /indexes/:index/_search`
- `POST /indexes/:index/_refresh`

### Create index

```bash
curl -X PUT http://localhost:4000/api/v1/search/indexes/articles \
  -H 'content-type: application/json' \
  -d '{
    "settings": {"number_of_shards": 2, "number_of_replicas": 1},
    "mappings": {
      "title": {"type": "text"},
      "body": {"type": "text"},
      "year": {"type": "integer"},
      "tag": {"type": "keyword"}
    }
  }'
```

### Index a document

```bash
curl -X PUT http://localhost:4000/api/v1/search/indexes/articles/documents/a1 \
  -H 'content-type: application/json' \
  -d '{
    "document": {
      "title": "Elixir in Practice",
      "body": "Building distributed systems with BEAM",
      "year": 2024,
      "tag": "elixir"
    }
  }'
```

### Search with query DSL + aggregation

```bash
curl -X POST http://localhost:4000/api/v1/search/indexes/articles/_search \
  -H 'content-type: application/json' \
  -d '{
    "query": {
      "bool": {
        "must": [
          {"match": {"body": {"query": "distributed systems", "operator": "and"}}}
        ],
        "filter": [
          {"range": {"year": {"gte": 2020}}}
        ]
      }
    },
    "aggs": {
      "by_tag": {"terms": {"field": "tag", "size": 10}}
    },
    "sort": [{"_score": "desc"}, {"_id": "asc"}],
    "size": 10
  }'
```

## Running tests

```bash
nix-shell --run "mix test"
```

Coverage mode:

```bash
nix-shell --run "mix test --cover"
```

Note: this project currently enforces a high global coverage threshold. If `mix test --cover` fails due to threshold, that is a project policy failure, not necessarily a functional regression.

## Project status and limitations

- Search engine persistence is in-memory in this MVP.
- WAL, segment files, snapshot/restore, and cross-node shard distribution are not fully implemented yet.
- Reverse proxy and search engine run in the same application process tree.

## Development notes

- Main app supervisor: `lib/reverse_proxy/application.ex`
- Proxy code: `lib/reverse_proxy/proxy/*`
- Discovery + control plane: `lib/reverse_proxy/discovery/*`, `lib/reverse_proxy/control_plane*`
- Search engine: `lib/reverse_proxy/search*`
- Search API controller: `lib/reverse_proxy_web/controllers/search_controller.ex`
- Router: `lib/reverse_proxy_web/router.ex`
