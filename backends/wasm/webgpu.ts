// WebGPU initialization and bridge

export interface GPUBridge {
  device: GPUDevice;
  context: GPUCanvasContext;
  canvas2d: CanvasRenderingContext2D;
  imports: Record<string, Function>;
}

// Debug state
let debugEnabled = true;
let mouseX = 0;
let mouseY = 0;
let keysPressedText = '';

export function setMousePos(x: number, y: number) {
  mouseX = x;
  mouseY = y;
}

export function setKeysPressed(keys: string) {
  keysPressedText = keys;
}

export async function initWebGPU(
  canvas: HTMLCanvasElement,
): Promise<GPUBridge> {
  if (!navigator.gpu) {
    throw new Error('WebGPU not supported');
  }

  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) {
    throw new Error('No WebGPU adapter found');
  }

  const device = await adapter.requestDevice();
  const context = canvas.getContext('webgpu');
  if (!context) {
    throw new Error('Failed to get WebGPU context');
  }

  const format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({
    device,
    format,
    alphaMode: 'opaque',
  });

  // Create 2D canvas overlay for drawing primitives
  // In a full WebGPU implementation, we'd use shaders for this
  const canvas2d = document.createElement('canvas');
  canvas2d.width = canvas.width;
  canvas2d.height = canvas.height;
  canvas2d.style.position = 'absolute';
  canvas2d.style.left = '0';
  canvas2d.style.top = '0';
  canvas2d.style.pointerEvents = 'none';
  canvas.parentElement?.appendChild(canvas2d);

  const ctx = canvas2d.getContext('2d');
  if (!ctx) {
    throw new Error('Failed to get 2D context');
  }

  // WASM imports for GPU operations
  const imports = {
    gpuClearScreen: (r: number, g: number, b: number, a: number) => {
      const textureView = context.getCurrentTexture().createView();
      const commandEncoder = device.createCommandEncoder();
      const renderPass = commandEncoder.beginRenderPass({
        colorAttachments: [
          {
            view: textureView,
            clearValue: { r, g, b, a },
            loadOp: 'clear' as const,
            storeOp: 'store' as const,
          },
        ],
      });
      renderPass.end();
      device.queue.submit([commandEncoder.finish()]);
    },

    gpuBeginFrame: () => {
      // Clear 2D canvas
      ctx.clearRect(0, 0, canvas2d.width, canvas2d.height);
    },

    gpuEndFrame: () => {
      // Draw debug overlay if enabled
      if (debugEnabled) {
        drawDebugOverlay(ctx, canvas2d.width, canvas2d.height);
      }
    },

    gpuDrawLine: (
      x1: number,
      y1: number,
      x2: number,
      y2: number,
      r: number,
      g: number,
      b: number,
      a: number,
    ) => {
      ctx.strokeStyle = `rgba(${r * 255}, ${g * 255}, ${b * 255}, ${a})`;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(x1, y1);
      ctx.lineTo(x2, y2);
      ctx.stroke();
    },

    gpuDrawCircle: (
      x: number,
      y: number,
      radius: number,
      r: number,
      g: number,
      b: number,
      a: number,
    ) => {
      ctx.strokeStyle = `rgba(${r * 255}, ${g * 255}, ${b * 255}, ${a})`;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(x, y, radius, 0, Math.PI * 2);
      ctx.stroke();
    },
  };

  return { device, context, canvas2d: ctx, imports };
}

function drawDebugOverlay(
  ctx: CanvasRenderingContext2D,
  width: number,
  height: number,
) {
  const padding = 16;
  const boxWidth = 280;
  const boxHeight = 140;
  const x = width - boxWidth - padding;
  const y = padding;

  // Draw semi-transparent background box (20% opacity)
  ctx.fillStyle = 'rgba(0, 0, 0, 0.2)';
  ctx.beginPath();
  ctx.roundRect(x, y, boxWidth, boxHeight, 8);
  ctx.fill();

  // Draw debug text (70% opacity)
  ctx.fillStyle = 'rgba(255, 255, 255, 0.7)';
  ctx.font = '14px monospace';

  let textY = y + 24;
  const lineHeight = 20;

  // Get debug info from global state (set by WASM exports)
  const debugInfo = (window as any).swindowzigDebug || {};

  ctx.fillText(`Tick: ${debugInfo.tick || 0}`, x + 12, textY);
  textY += lineHeight;

  ctx.fillText(`Mouse: ${mouseX.toFixed(0)}, ${mouseY.toFixed(0)}`, x + 12, textY);
  textY += lineHeight;

  ctx.fillText(`Keys: ${keysPressedText || 'none'}`, x + 12, textY);
  textY += lineHeight;

  ctx.fillText(`Ship: ${debugInfo.shipAlive ? 'alive' : 'dead'}`, x + 12, textY);
  textY += lineHeight;

  ctx.fillText(`Asteroids: ${debugInfo.asteroidCount || 0}`, x + 12, textY);
  textY += lineHeight;

  ctx.fillText(`Score: ${debugInfo.score || 0}`, x + 12, textY);
}
