/// <reference types="vite/client" />

declare module 'encoding-japanese' {
  const Encoding: {
    detect(data: number[] | Uint8Array): string | false;
  };
  export = Encoding;
}
