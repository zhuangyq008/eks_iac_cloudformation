package com.example.demo;

import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class InfoController {

  private final String version;
  private final String podName;

  public InfoController(@Value("${app.version:dev}") String version,
                        @Value("${POD_NAME:local}") String podName) {
    this.version = version;
    this.podName = podName;
  }

  @GetMapping("/")
  public Map<String, String> info() {
    return Map.of(
        "app", "springboot-demo",
        "version", version,
        "pod", podName,
        "java", System.getProperty("java.version"),
        "arch", System.getProperty("os.arch"));
  }
}
