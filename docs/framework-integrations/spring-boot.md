# Joubako with Spring Boot

This integration connects a Nim/Joubako client to a Spring Boot REST
controller. Records provide a compact request and response schema, while HTTP
statuses remain explicit in the controller.

## Backend implementation

```java
@RestController
@RequestMapping("/api")
class DemoController {
    @GetMapping("/health")
    Map<String, Object> health() {
        return Map.of("ok", true, "framework", "Spring Boot");
    }

    @PostMapping("/messages")
    ResponseEntity<?> message(
        @RequestBody MessageRequest request,
        @RequestHeader(value = "X-Joubako-Demo", defaultValue = "unknown") String client
    ) {
        if (request.priority() < 1 || request.priority() > 5) {
            return ResponseEntity.unprocessableContent()
                .body(Map.of("error", "invalid message"));
        }
        return ResponseEntity.status(HttpStatus.CREATED)
            .body(new MessageResponse(true, request.text(), request.priority(),
                "Spring Boot", client));
    }
}
```

See the complete
[`DemoApplication.java`](../../examples/frameworks/spring-boot/src/main/java/dev/joubako/examples/DemoApplication.java).

## Build and run Spring Boot

Java 21 and Maven 3.9 or newer are required.

```sh
cd examples/frameworks/spring-boot
mvn package
java -jar target/joubako-spring-boot-demo-0.1.0.jar
```

## Call Spring Boot from Joubako

```sh
JOUBAKO_DEMO_BASE_URL=http://127.0.0.1:8085/ \
  JOUBAKO_DEMO_EXPECTED_FRAMEWORK="Spring Boot" \
  nim c -r --mm:arc -d:ssl --path:src examples/frameworks/client.nim
```

The integration is built and executed in CI with both ARC and ORC Joubako
clients.

## Production notes

Add Bean Validation, Spring Security, deployment observability, and explicit
server request limits appropriate to the service. Configure the Joubako
client's deadlines and retry policy according to the endpoint's idempotency.
