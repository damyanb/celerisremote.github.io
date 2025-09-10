import {WebMMuxer} from "./webm-muxer.js";
import { calc_constants } from './constants_load_calc.js';  // variables and functions needed for init_sim_parameters

const canvas = document.getElementById('webgpuCanvas');

let muxer, videoEncoder, fileStream;

async function initMuxer(){
    let fileHandle = await window.showSaveFilePicker({
        suggestedName: `video.webm`,
        types: [{
            description: 'Video File',
            accept: { 'video/webm': ['.webm'] }
        }],
    });    
    fileStream = await fileHandle.createWritable();        
    muxer = new WebMMuxer.Muxer({
        target: new WebMMuxer.FileSystemWritableFileStreamTarget(fileStream, {onData:()=>console.log("new data recevied")}),
        video: {
            codec: 'V_VP9',
            width: canvas.width,
            height: canvas.height
        }
    });
}

export function initVideo(){
    initMuxer().then(()=>{
        videoEncoder = new VideoEncoder({
            output: (chunk, meta) =>{
                // console.log("adding chunk!");
                muxer.addVideoChunk(chunk, meta)
            },
            error: e => console.error(e)
        });        

        videoEncoder.configure({
            codec: 'vp09.00.10.08',
            // codec: 'vp8',
            width: canvas.width,
            height: canvas.height,
            // bitrate: 1e6,
            framerate: 30
        });
        console.log("canvas", canvas.width, canvas.height);
    });


}



let saved = false;

// Add frames to the encoder
let frameCount = -1;
const skip = 1;
export function addFrame() {
    if(saved) return;
    if(!videoEncoder) {
        
        return;
    }
    frameCount++;
    if(frameCount % skip !== 0) return; 

    const timestamp = parseInt(frameCount/skip) * 1/30 * 1000000;
    // console.log("video frame count=", frameCount/skip);
    const frame = new VideoFrame(canvas, {timestamp});
    videoEncoder.encode(frame, { keyFrame: frameCount   % 90 ===0 });

    if(frameCount % 30 === 0 ){console.log(`flushing #${Math.floor(frameCount/30)}  at frame ${frameCount}`,); videoEncoder.flush()};

    frame.close(); // Free memory
}


document.getElementById('start-recording-btn').addEventListener('click', async function (){
    initVideo();
});
document.getElementById('stop-recording-btn').addEventListener('click', async function (){
    calc_constants.simPause = 1;
    console.log("stopping recording now")
    saved = true;
    const startFlushTime = performance.now();
    await videoEncoder.flush();
    const endFlushTime = performance.now();
    console.log(`Flush duration: ${(endFlushTime - startFlushTime).toFixed(2)} ms`);

    muxer.finalize();
    const startFileStreamTime = performance.now();
    await fileStream.close();
    const endFileStreamTime = performance.now();
    console.log(`FileStream duration: ${(endFileStreamTime - startFileStreamTime).toFixed(2)} ms`);

    console.log("Video saved!");
});