import { Config } from '@remotion/cli/config';

// 渲染器在 iframe 里按虚拟时钟一帧一帧往前走；多个标签页并行时，每个标签页从自己那段的开头快进，结果一样。
Config.setVideoImageFormat('jpeg');
Config.setJpegQuality(92);
Config.setCodec('h264');
Config.setCrf(16);
Config.setPixelFormat('yuv420p');
Config.setDelayRenderTimeoutInMilliseconds(120000);
