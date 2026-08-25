package main

import (
	"net/http"
	"os"

	"github.com/gin-gonic/gin"
)

type messageRequest struct {
	Text     string `json:"text" binding:"required,min=1,max=200"`
	Priority int    `json:"priority" binding:"required,min=1,max=5"`
}

func main() {
	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.Use(gin.Recovery())

	router.GET("/api/health", func(context *gin.Context) {
		context.JSON(http.StatusOK, gin.H{
			"ok":        true,
			"framework": "Gin",
		})
	})

	router.GET("/api/users/:id", func(context *gin.Context) {
		if context.Param("id") != "1" {
			context.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
			return
		}

		context.JSON(http.StatusOK, gin.H{
			"id":    1,
			"name":  "Gin User",
			"email": "gin@example.test",
		})
	})

	router.POST("/api/messages", func(context *gin.Context) {
		context.Request.Body = http.MaxBytesReader(
			context.Writer,
			context.Request.Body,
			16*1024,
		)

		var request messageRequest
		if err := context.ShouldBindJSON(&request); err != nil {
			context.JSON(http.StatusUnprocessableEntity, gin.H{"error": "invalid message"})
			return
		}

		client := context.GetHeader("X-Joubako-Demo")
		if client == "" {
			client = "unknown"
		}

		context.JSON(http.StatusCreated, gin.H{
			"accepted":  true,
			"text":      request.Text,
			"priority":  request.Priority,
			"framework": "Gin",
			"client":    client,
		})
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8082"
	}

	if err := router.Run("127.0.0.1:" + port); err != nil {
		panic(err)
	}
}
