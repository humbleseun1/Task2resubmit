package microservices

default allow = false

# Allow product service to be called by anyone
allow {
  input.path = ["products"]
}

allow {
  input.path = ["products", id]
}

allow {
  input.path = ["health"]
}

# Allow order service to be called by authorized clients
allow {
  input.path = ["orders"]
  input.source_service = "apisix"
}

allow {
  input.path = ["orders", id]
  input.source_service = "apisix"
}

# Allow order service to call product service
allow {
  input.path = ["products", id]
  input.source_service = "order-service"
  input.method = "GET"
}

allow {
  input.path = ["products", id]
  input.source_service = "order-service"
  input.method = "PUT"
}