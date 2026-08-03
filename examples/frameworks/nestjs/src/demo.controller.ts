import {
  Body,
  Controller,
  Get,
  Headers,
  NotFoundException,
  Param,
  ParseIntPipe,
  Post,
} from "@nestjs/common";

import { MessageDto } from "./message.dto";

@Controller("api")
export class DemoController {
  @Get("health")
  health() {
    return { ok: true, framework: "NestJS" };
  }

  @Get("users/:id")
  user(@Param("id", ParseIntPipe) id: number) {
    if (id !== 1) {
      throw new NotFoundException("user not found");
    }

    return {
      id,
      name: "NestJS User",
      email: "nestjs@example.test",
    };
  }

  @Post("messages")
  message(
    @Body() payload: MessageDto,
    @Headers("x-joubako-demo") client = "unknown",
  ) {
    return {
      accepted: true,
      text: payload.text,
      priority: payload.priority,
      framework: "NestJS",
      client,
    };
  }
}
