import { Module } from "@nestjs/common";

import { DemoController } from "./demo.controller";

@Module({
  controllers: [DemoController],
})
export class AppModule {}
