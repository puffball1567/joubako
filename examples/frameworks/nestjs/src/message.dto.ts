import { IsInt, IsNotEmpty, IsString, Max, MaxLength, Min } from "class-validator";

export class MessageDto {
  @IsString()
  @IsNotEmpty()
  @MaxLength(200)
  text!: string;

  @IsInt()
  @Min(1)
  @Max(5)
  priority!: number;
}
