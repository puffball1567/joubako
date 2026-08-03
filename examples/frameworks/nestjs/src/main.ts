import "reflect-metadata";

import { UnprocessableEntityException, ValidationPipe } from "@nestjs/common";
import { NestFactory } from "@nestjs/core";

import { AppModule } from "./app.module";

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule);
  app.useGlobalPipes(
    new ValidationPipe({
      exceptionFactory: (errors) => new UnprocessableEntityException(errors),
      forbidNonWhitelisted: true,
      transform: true,
      whitelist: true,
    }),
  );

  const port = Number.parseInt(process.env.PORT ?? "3001", 10);
  await app.listen(port, "127.0.0.1");
  console.log(`NestJS demo listening on http://127.0.0.1:${port}`);
}

void bootstrap();
