package com.example.demo;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.Map;
import org.junit.jupiter.api.Test;

class InfoControllerTest {

  @Test
  void infoReturnsVersionAndPod() {
    Map<String, String> info = new InfoController("1.2.3", "pod-a").info();

    assertThat(info)
        .containsEntry("app", "springboot-demo")
        .containsEntry("version", "1.2.3")
        .containsEntry("pod", "pod-a")
        .containsKeys("java", "arch");
  }
}
