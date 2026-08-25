package dev.joubako.examples;

import java.util.Map;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@SpringBootApplication
public class DemoApplication {
    public static void main(String[] args) {
        SpringApplication.run(DemoApplication.class, args);
    }
}

@RestController
@RequestMapping("/api")
class DemoController {
    @GetMapping("/health")
    Map<String, Object> health() {
        return Map.of("ok", true, "framework", "Spring Boot");
    }

    @GetMapping("/users/{id}")
    ResponseEntity<?> user(@PathVariable long id) {
        if (id != 1) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND)
                .body(Map.of("error", "user not found"));
        }

        return ResponseEntity.ok(Map.of(
            "id", id,
            "name", "Spring Boot User",
            "email", "spring@example.test"
        ));
    }

    @PostMapping("/messages")
    ResponseEntity<?> message(
        @RequestBody MessageRequest request,
        @RequestHeader(value = "X-Joubako-Demo", defaultValue = "unknown") String client
    ) {
        if (request.text() == null || request.text().isEmpty() ||
            request.text().length() > 200 || request.priority() < 1 || request.priority() > 5) {
            return ResponseEntity.unprocessableContent()
                .body(Map.of("error", "invalid message"));
        }

        return ResponseEntity.status(HttpStatus.CREATED).body(new MessageResponse(
            true,
            request.text(),
            request.priority(),
            "Spring Boot",
            client
        ));
    }
}

record MessageRequest(String text, int priority) {}

record MessageResponse(
    boolean accepted,
    String text,
    int priority,
    String framework,
    String client
) {}
