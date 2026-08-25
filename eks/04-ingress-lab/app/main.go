package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/sts"
)

type IdentityResponse struct {
	Pod       string `json:"pod"`
	Node      string `json:"node"`
	Namespace string `json:"namespace"`
	Account   string `json:"account,omitempty"`
	Arn       string `json:"arn,omitempty"`
	UserID    string `json:"userId,omitempty"`
	Error     string `json:"error,omitempty"`
}

type S3Response struct {
	Pod     string `json:"pod"`
	Bucket  string `json:"bucket,omitempty"`
	Key     string `json:"key,omitempty"`
	Content string `json:"content,omitempty"`
	Error   string `json:"error,omitempty"`
}

func identityHandler(w http.ResponseWriter, r *http.Request) {
	resp := IdentityResponse{
		Pod:       os.Getenv("POD_NAME"),
		Node:      os.Getenv("NODE_NAME"),
		Namespace: os.Getenv("POD_NAMESPACE"),
	}

	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		resp.Error = fmt.Sprintf("no credentials available: %v", err)
		writeJSON(w, http.StatusOK, resp)
		return
	}

	client := sts.NewFromConfig(cfg)
	output, err := client.GetCallerIdentity(context.Background(), &sts.GetCallerIdentityInput{})
	if err != nil {
		resp.Error = fmt.Sprintf("sts:GetCallerIdentity failed: %v", err)
		writeJSON(w, http.StatusOK, resp)
		return
	}

	resp.Account = *output.Account
	resp.Arn = *output.Arn
	resp.UserID = *output.UserId
	writeJSON(w, http.StatusOK, resp)
}

func s3Handler(w http.ResponseWriter, r *http.Request) {
	resp := S3Response{
		Pod:    os.Getenv("POD_NAME"),
		Bucket: os.Getenv("S3_BUCKET"),
		Key:    os.Getenv("S3_KEY"),
	}

	if resp.Bucket == "" || resp.Key == "" {
		resp.Error = "S3_BUCKET y S3_KEY no están definidos (agrégalos en el Deployment)"
		writeJSON(w, http.StatusOK, resp)
		return
	}

	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		resp.Error = fmt.Sprintf("no credentials available: %v", err)
		writeJSON(w, http.StatusOK, resp)
		return
	}

	client := s3.NewFromConfig(cfg)
	output, err := client.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(resp.Bucket),
		Key:    aws.String(resp.Key),
	})
	if err != nil {
		resp.Error = fmt.Sprintf("s3:GetObject failed: %v", err)
		writeJSON(w, http.StatusOK, resp)
		return
	}
	defer output.Body.Close()

	body, err := io.ReadAll(output.Body)
	if err != nil {
		resp.Error = fmt.Sprintf("reading object failed: %v", err)
		writeJSON(w, http.StatusOK, resp)
		return
	}

	resp.Content = string(body)
	writeJSON(w, http.StatusOK, resp)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func main() {
	http.HandleFunc("/identity", identityHandler)
	http.HandleFunc("/s3", s3Handler)
	http.HandleFunc("/healthz", healthHandler)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
