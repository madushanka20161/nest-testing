import { Injectable } from '@nestjs/common';

@Injectable()
export class AppService {
  getHello(): string {
    return 'Hello World! '+ new Date().toISOString() + ' test 01 + new commit';
  }
}
