# Configuration variables - modify these as needed
DOCKER_REGISTRY ?= your-docker-registry  # Replace with your Docker registry
NAMESPACE ?= microservices-demo
KUBECTL ?= kubectl
HELM ?= helm
DOCKER ?= docker
MINIKUBE ?= minikube

# Default target when just 'make' is executed
.PHONY: all
all: help

# Help target
.PHONY: help
help:
	@echo "Microservices Demo Project Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  setup              - Set up the local development environment (starts minikube)"
	@echo "  build              - Build Docker images for all services"
	@echo "  push               - Push Docker images to registry"
	@echo "  deploy-infra       - Deploy infrastructure components (YugabyteDB, OPA, KEDA, APISIX)"
	@echo "  deploy-services    - Deploy microservices (product-service, order-service)"
	@echo "  deploy-all         - Deploy everything (infrastructure + services)"
	@echo "  clean              - Remove deployed resources"
	@echo "  test               - Run tests against deployed services"
	@echo "  logs               - Show logs from all services"
	@echo "  status             - Show status of all deployed components"
	@echo "  port-forward       - Set up port forwarding to access services locally"
	@echo ""
	@echo "Example usage:"
	@echo "  make setup         - Start minikube and set up environment"
	@echo "  make deploy-all    - Deploy the complete solution"
	@echo "  make test          - Test the deployed services"
	@echo ""
	@echo "Configuration:"
	@echo "  DOCKER_REGISTRY    - Docker registry to use (default: $(DOCKER_REGISTRY))"
	@echo "  NAMESPACE          - Kubernetes namespace (default: $(NAMESPACE))"

# Check for required tools
REQUIRED_TOOLS := minikube kubectl helm docker
check_tools:
	@for tool in $(REQUIRED_TOOLS); do \
		if ! command -v $$tool >/dev/null 2>&1; then \
			echo "Error: '$$tool' is not installed or not in PATH"; \
			echo "Please install '$$tool' before continuing."; \
			exit 1; \
		fi; \
	done

# Check system resources
check_resources:
	@free_memory=$$(free -m | awk '/^Mem:/{print $$2}'); \
	if [ $$free_memory -lt 4096 ]; then \
		echo "Error: Insufficient memory. At least 4GB RAM required."; \
		exit 1; \
	fi
	@cpu_cores=$$(nproc); \
	if [ $$cpu_cores -lt 2 ]; then \
		echo "Error: Insufficient CPU cores. At least 2 cores required."; \
		exit 1; \
	fi

# Setup local development environment using minikube
.PHONY: setup
setup: check_tools check_resources
	@echo "Checking dependencies and system requirements..."
	@echo "Setting up minikube..."
	-$(MINIKUBE) delete || true
	$(MINIKUBE) start --memory=4096 --cpus=4 || { \
		echo "Error: Failed to start minikube."; \
		echo "Please ensure virtualization is enabled and you have sufficient system resources."; \
		exit 1; \
	}
	$(MINIKUBE) addons enable ingress
	@echo "Creating namespace $(NAMESPACE)..."
	$(KUBECTL) create namespace $(NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	@echo "Setting up Helm repositories..."
	$(HELM) repo add kedacore https://kedacore.github.io/charts
	$(HELM) repo add apisix https://charts.apiseven.com
	$(HELM) repo update
	@echo "Setup complete! Run 'make deploy-all' to deploy the project."

# Build Docker images
.PHONY: build
build:
	@echo "Building Docker images..."
	@echo "Setting docker env to use minikube's Docker daemon..."
	@eval $$(minikube docker-env)
	cd product-service && $(DOCKER) build -t $(DOCKER_REGISTRY)/product-service:latest .
	cd order-service && $(DOCKER) build -t $(DOCKER_REGISTRY)/order-service:latest .
	@echo "Docker images built successfully!"

# Push Docker images to registry
.PHONY: push
push:
	@echo "Pushing Docker images to registry..."
	$(DOCKER) push $(DOCKER_REGISTRY)/product-service:latest
	$(DOCKER) push $(DOCKER_REGISTRY)/order-service:latest
	@echo "Docker images pushed successfully!"

# Deploy infrastructure components
.PHONY: deploy-infra
deploy-infra:
	@echo "Deploying YugabyteDB..."
	$(KUBECTL) apply -f kubernetes/yugabytedb/yugabyte-statefulset.yaml
	
	@echo "Waiting for YugabyteDB to be ready..."
	$(KUBECTL) wait --for=condition=Ready pod/yugabytedb-0 -n $(NAMESPACE) --timeout=300s
	
	@echo "Deploying Open Policy Agent..."
	$(KUBECTL) apply -f kubernetes/opa/opa-deployment.yaml
	
	@echo "Installing KEDA..."
	$(HELM) install keda kedacore/keda --namespace keda --create-namespace
	
	@echo "Deploying KEDA Scalers..."
	$(KUBECTL) apply -f kubernetes/keda/keda-scaler.yaml
	
	@echo "Installing APISIX..."
	$(HELM) install apisix apisix/apisix --namespace $(NAMESPACE)
	
	@echo "Deploying APISIX Routes..."
	$(KUBECTL) apply -f kubernetes/apisix/apisix-config.yaml
	
	@echo "Infrastructure components deployed successfully!"

# Deploy microservices
.PHONY: deploy-services
deploy-services:
	@echo "Deploying Product Service..."
	sed "s|\$${DOCKER_REGISTRY}|$(DOCKER_REGISTRY)|g" kubernetes/product-service/deployment.yaml | $(KUBECTL) apply -f -
	
	@echo "Deploying Order Service..."
	sed "s|\$${DOCKER_REGISTRY}|$(DOCKER_REGISTRY)|g" kubernetes/order-service/deployment.yaml | $(KUBECTL) apply -f -
	
	@echo "Microservices deployed successfully!"

# Deploy everything
.PHONY: deploy-all
deploy-all: deploy-infra deploy-services
	@echo "All components deployed successfully!"

# Clean up deployed resources
.PHONY: clean
clean:
	@echo "Removing deployed resources..."
	-$(KUBECTL) delete -f kubernetes/product-service/deployment.yaml --ignore-not-found
	-$(KUBECTL) delete -f kubernetes/order-service/deployment.yaml --ignore-not-found
	-$(KUBECTL) delete -f kubernetes/apisix/apisix-config.yaml --ignore-not-found
	-$(HELM) uninstall apisix --namespace $(NAMESPACE)
	-$(KUBECTL) delete -f kubernetes/keda/keda-scaler.yaml --ignore-not-found
	-$(HELM) uninstall keda --namespace keda
	-$(KUBECTL) delete -f kubernetes/opa/opa-deployment.yaml --ignore-not-found
	-$(KUBECTL) delete -f kubernetes/yugabytedb/yugabyte-statefulset.yaml --ignore-not-found
	@echo "Resources removed successfully!"

# Run tests
.PHONY: test
test:
	@echo "Getting APISIX Gateway IP..."
	$(eval GATEWAY_IP=$(shell minikube ip))
	$(eval APISIX_PORT=$(shell kubectl get svc apisix-gateway -n $(NAMESPACE) -o jsonpath='{.spec.ports[0].nodePort}'))
	@echo "Gateway endpoint: http://$(GATEWAY_IP):$(APISIX_PORT)"
	
	@echo "Testing Product Service..."
	curl -X POST http://$(GATEWAY_IP):$(APISIX_PORT)/products -H "Content-Type: application/json" \
		-d '{"name":"Test Product","price":19.99,"stock":100}'
	@echo ""
	curl http://$(GATEWAY_IP):$(APISIX_PORT)/products
	@echo ""
	
	@echo "Testing Order Service..."
	curl -X POST http://$(GATEWAY_IP):$(APISIX_PORT)/orders -H "Content-Type: application/json" \
		-d '{"customerId":1,"productId":1,"quantity":2}'
	@echo ""
	curl http://$(GATEWAY_IP):$(APISIX_PORT)/orders
	@echo ""
	
	@echo "Tests completed successfully!"

# Show logs from all services
.PHONY: logs
logs:
	@echo "Showing logs for Product Service..."
	$(KUBECTL) logs -l app=product-service -n $(NAMESPACE) --tail=50
	
	@echo "Showing logs for Order Service..."
	$(KUBECTL) logs -l app=order-service -n $(NAMESPACE) --tail=50

# Show status of all deployed components
.PHONY: status
status:
	@echo "Checking pod status..."
	$(KUBECTL) get pods -n $(NAMESPACE)
	
	@echo "Checking services..."
	$(KUBECTL) get svc -n $(NAMESPACE)
	
	@echo "Checking APISIX routes..."
	$(KUBECTL) get apisixroute -n $(NAMESPACE)
	
	@echo "Checking KEDA scalers..."
	$(KUBECTL) get scaledobject -n $(NAMESPACE)

# Set up port forwarding to access services locally
.PHONY: port-forward
port-forward:
	@echo "Setting up port forwarding for APISIX Gateway..."
	$(KUBECTL) port-forward svc/apisix-gateway -n $(NAMESPACE) 8080:80 &
	@echo "APISIX Gateway available at http://localhost:8080"
	@echo "Use Ctrl+C to stop port forwarding"