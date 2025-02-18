package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"

	"github.com/gorilla/mux"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

// Order represents the order entity
type Order struct {
	ID         uint    `json:"id" gorm:"primaryKey"`
	CustomerID uint    `json:"customerId"`
	ProductID  uint    `json:"productId"`
	Quantity   int     `json:"quantity"`
	TotalPrice float64 `json:"totalPrice"`
	Status     string  `json:"status"`
}

// Product struct for fetching product details
type Product struct {
	ID    uint    `json:"id"`
	Name  string  `json:"name"`
	Price float64 `json:"price"`
	Stock int     `json:"stock"`
}

var db *gorm.DB

func main() {
	// Get database connection details from environment variables
	dbHost := getEnv("DB_HOST", "yugabytedb")
	dbPort := getEnv("DB_PORT", "5433")
	dbUser := getEnv("DB_USER", "yugabyte")
	dbPassword := getEnv("DB_PASSWORD", "yugabyte")
	dbName := getEnv("DB_NAME", "yugabyte")

	// Connect to YugabyteDB
	dsn := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable", 
		dbHost, dbPort, dbUser, dbPassword, dbName)
	
	var err error
	db, err = gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	
	// Auto migrate the schema
	db.AutoMigrate(&Order{})

	// Create router
	r := mux.NewRouter()
	
	// Define routes
	r.HandleFunc("/orders", getOrders).Methods("GET")
	r.HandleFunc("/orders/{id}", getOrder).Methods("GET")
	r.HandleFunc("/orders", createOrder).Methods("POST")
	r.HandleFunc("/orders/{id}/status", updateOrderStatus).Methods("PATCH")
	r.HandleFunc("/health", healthCheck).Methods("GET")

	// Start server
	port := getEnv("PORT", "8080")
	log.Printf("Starting order service on port %s", port)
	log.Fatal(http.ListenAndServe(":"+port, r))
}

func getOrders(w http.ResponseWriter, r *http.Request) {
	var orders []Order
	result := db.Find(&orders)
	if result.Error != nil {
		http.Error(w, result.Error.Error(), http.StatusInternalServerError)
		return
	}
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(orders)
}

func getOrder(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	id, err := strconv.Atoi(vars["id"])
	if err != nil {
		http.Error(w, "Invalid order ID", http.StatusBadRequest)
		return
	}
	
	var order Order
	result := db.First(&order, id)
	if result.Error != nil {
		http.Error(w, "Order not found", http.StatusNotFound)
		return
	}
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(order)
}

func createOrder(w http.ResponseWriter, r *http.Request) {
	var order Order
	err := json.NewDecoder(r.Body).Decode(&order)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	
	// Get product details from product service
	productServiceURL := getEnv("PRODUCT_SERVICE_URL", "http://product-service:8080")
	productURL := fmt.Sprintf("%s/products/%d", productServiceURL, order.ProductID)
	
	resp, err := http.Get(productURL)
	if err != nil {
		http.Error(w, "Failed to fetch product details", http.StatusInternalServerError)
		return
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		http.Error(w, "Product not found", http.StatusBadRequest)
		return
	}
	
	var product Product
	err = json.NewDecoder(resp.Body).Decode(&product)
	if err != nil {
		http.Error(w, "Failed to decode product details", http.StatusInternalServerError)
		return
	}
	
	// Check if enough stock is available
	if product.Stock < order.Quantity {
		http.Error(w, "Not enough stock available", http.StatusBadRequest)
		return
	}
	
	// Calculate total price
	order.TotalPrice = product.Price * float64(order.Quantity)
	order.Status = "pending"
	
	// Create the order
	result := db.Create(&order)
	if result.Error != nil {
		http.Error(w, result.Error.Error(), http.StatusInternalServerError)
		return
	}
	
	// Update product stock
	product.Stock -= order.Quantity
	updateProductURL := fmt.Sprintf("%s/products/%d", productServiceURL, product.ID)
	
	productJSON, _ := json.Marshal(product)
	req, _ := http.NewRequest("PUT", updateProductURL, bytes.NewBuffer(productJSON))
	req.Header.Set("Content-Type", "application/json")
	
	updateResp, err := http.DefaultClient.Do(req)
	if err != nil || updateResp.StatusCode != http.StatusOK {
		// If updating product fails, rollback order creation
		db.Delete(&order)
		http.Error(w, "Failed to update product stock", http.StatusInternalServerError)
		return
	}
	updateResp.Body.Close()
	
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(order)
}

func updateOrderStatus(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	id, err := strconv.Atoi(vars["id"])
	if err != nil {
		http.Error(w, "Invalid order ID", http.StatusBadRequest)
		return
	}
	
	var order Order
	result := db.First(&order, id)
	if result.Error != nil {
		http.Error(w, "Order not found", http.StatusNotFound)
		return
	}
	
	var statusUpdate struct {
		Status string `json:"status"`
	}
	
	err = json.NewDecoder(r.Body).Decode(&statusUpdate)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	
	// Update order status
	order.Status = statusUpdate.Status
	db.Save(&order)
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(order)
}

func healthCheck(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("healthy"))
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}