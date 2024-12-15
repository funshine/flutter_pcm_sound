class PCMProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this._queue = [];
    this.numChannels = 1;
    this.feedThreshold = 8000;
    this.invokedFeedCallback = false;

    this.port.onmessage = (event) => {
      const data = event.data;
      if (!data) return;
      switch (data.type) {
        case 'config':
          this.numChannels = data.numChannels;
          this.port.postMessage({type: 'configured'});
          break;
        case 'configThreshold':
          this.feedThreshold = data.feedThreshold;
          break;
        case 'samples':
          // Append incoming PCM data to the queue as Int16
          const samples = data.samples;
          if (samples && samples.length > 0) {
            this._queue.push(new Int16Array(samples));
            this.invokedFeedCallback = false;
          }
          break;
      }
    };
  }

  process(inputs, outputs, parameters) {
    const output = outputs[0];
    const framesNeeded = output[0].length;
    let framePos = 0;

    while (framePos < framesNeeded && this._queue.length > 0) {
      const currentBuffer = this._queue[0];
      const framesFromBuffer = Math.min(
        currentBuffer.length / this.numChannels,
        framesNeeded - framePos
      );

      for (let f = 0; f < framesFromBuffer; f++) {
        for (let ch = 0; ch < this.numChannels; ch++) {
          const sampleInt = currentBuffer[f * this.numChannels + ch];
          const sampleFloat = sampleInt / 32768.0;
          output[ch][framePos + f] = sampleFloat;
        }
      }

      const usedSamples = framesFromBuffer * this.numChannels;
      if (usedSamples < currentBuffer.length) {
        this._queue[0] = currentBuffer.slice(usedSamples);
      } else {
        this._queue.shift();
      }
      framePos += framesFromBuffer;
    }

    while (framePos < framesNeeded) {
      for (let ch = 0; ch < this.numChannels; ch++) {
        output[ch][framePos] = 0.0;
      }
      framePos++;
    }

    let totalSamples = 0;
    for (const b of this._queue) {
      totalSamples += b.length;
    }
    const remainingFrames = totalSamples / this.numChannels;

    if (remainingFrames <= this.feedThreshold && !this.invokedFeedCallback) {
      this.invokedFeedCallback = true;
      this.port.postMessage({
        type: 'requestMoreData',
        remainingFrames: remainingFrames
      });
    }

    return true;
  }
}

registerProcessor('pcm-processor', PCMProcessor);
