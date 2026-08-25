# Joubako with Gin

This integration connects Joubako to a Gin JSON API. Gin's binding tags enforce
the same message constraints expected by the typed Nim client.

## Backend implementation

```go
type messageRequest struct {
	Text     string `json:"text" binding:"required,min=1,max=200"`
	Priority int    `json:"priority" binding:"required,min=1,max=5"`
}

router.POST("/api/messages", func(context *gin.Context) {
	var request messageRequest
	if err := context.ShouldBindJSON(&request); err != nil {
		context.JSON(http.StatusUnprocessableEntity,
			gin.H{"error": "invalid message"})
		return
	}

	context.JSON(http.StatusCreated, gin.H{
		"accepted": true,
		"text": request.Text,
		"priority": request.Priority,
		"framework": "Gin",
	})
})
```

The runnable server also wraps the body with `http.MaxBytesReader`. See
[`main.go`](../../examples/frameworks/gin/main.go).

## Run Gin

Go 1.25 or newer is required by the pinned demo module.

```sh
cd examples/frameworks/gin
go run .
```

## Call Gin from Joubako

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8082/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK=Gin \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

The integration is built and executed in CI with both ARC and ORC Joubako
clients.

## Production notes

Retain a finite request-body limit, configure trusted proxies explicitly, and
add the service's authentication, recovery, access logging, and rate-limiting
middleware. Do not retry non-idempotent operations unless the API supplies an
idempotency mechanism.
