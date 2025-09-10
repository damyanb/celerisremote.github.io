import {WebMMuxer} from "./webm-muxer.js";
import { calc_constants } from './constants_load_calc.js';  // variables and functions needed for init_sim_parameters
import {total_time} from './main.js';

const canvas = document.getElementById('webgpuCanvas');

let muxer, videoEncoder, fileStream, subtitleEncoder;

const webvttHeader = "WEBVTT";
let simpleWebvttFile =
`WEBVTT

00:00:00.000 --> 00:00:10.000
Example entry 1: Hello <b>world</b>.
`;

let webvttEntries = []; // list of [time, entry];


const formattedSeconds = (num => num.toFixed(3).replace(/^(\d)\./, '0$1.'));
function secondsToTime(totalSeconds) {
    // Calculate hours
    const hours = Math.floor(totalSeconds / 3600);

    // Calculate remaining seconds after hours
    const remainingSecondsAfterHours = totalSeconds % 3600;

    // Calculate minutes
    const minutes = Math.floor(remainingSecondsAfterHours / 60);

    // Calculate remaining seconds after minutes
    const seconds = remainingSecondsAfterHours % 60;
    

    // Format as hh:mm:ss
    return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${formattedSeconds(seconds)}`;
}
function secondsToEntry(seconds, cueSeconds){
    const lastEntryTimestamp = webvttEntries?.[webvttEntries.length-1]?.[0] ?? 0;
    
    const time0String = secondsToTime(lastEntryTimestamp);
    const time1String = secondsToTime(seconds);
    const cueText =  cueSeconds.toFixed(2);
    const entry=
`\n\n${time0String} --> ${time1String}
Tiempo: ${cueSeconds}`;
    return entry;
}

async function initMuxer(fileHandle){  
    fileStream = await fileHandle.createWritable();        
    muxer = new WebMMuxer.Muxer({
        target: new WebMMuxer.FileSystemWritableFileStreamTarget(fileStream, {onData:()=>console.log("new data recevied")}),
        video: {
            codec: 'V_VP9',
            width: canvas.width,
            height: canvas.height
        },
        subtitles: {
            codec: 'S_TEXT/WEBVTT'
        },
    });

    subtitleEncoder = new WebMMuxer.SubtitleEncoder({
        output: (chunk, meta) =>{
            console.log("writing subtitles"); 
            muxer.addSubtitleChunk(chunk, meta)
        },
        error: e => console.error(e)
    });
    subtitleEncoder.configure({
        codec: 'webvtt'
    });
    
    
    // subtitleEncoder.encode(simpleWebvttFile);    
}


export async function initVideo(fileHandler){
    initMuxer(fileHandler).then(()=>{
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
            bitrate: 5e6,
            framerate: 30
        });
        console.log("canvas", canvas.width, canvas.height);
    });


}



let saved = false;

// Add frames to the encoder
let frameCount = -1;
const skip = 2;
const fps = 30;
const times=[];
window.times = times;
export function addFrame() {
    if(saved) return;
    if(!videoEncoder) {
        return;
    }
    if(calc_constants.simPause===1) return;
    frameCount++;
    const videoFrameCount = parseInt(frameCount/skip);
    if(frameCount % skip !== 0) return; 
    

    console.log("videoFrameCount", videoFrameCount)
    const timestamp = videoFrameCount * 1/fps * 1_000_000;
    times.push(total_time);

    // console.log("video frame count=", frameCount/skip);
    const frame = new VideoFrame(canvas, {timestamp});
    videoEncoder.encode(frame, { keyFrame: videoFrameCount % 30 ===0 });
    webvttEntries = [...webvttEntries, [timestamp/1_000_000, secondsToEntry(timestamp/1_000_000)]];

    // flushing
    if(videoFrameCount % fps === 0 ){

        videoEncoder.flush()
        console.log(`flushing #${Math.floor(frameCount/30 / skip)}  at frame ${frameCount} and t =${total_time.toFixed(2)}s`,); 
        
        
    };

    frame.close(); // Free memory
}


document.getElementById('start-recording-btn').addEventListener('click', async function (){
    
    initVideo();
});
document.getElementById('stop-recording-btn').addEventListener('click', async function (){

    const entriesToSave = webvttEntries.slice(0,-1);
    webvttEntries = webvttEntries.slice(-1);

    const webvttFile = [webvttHeader, entriesToSave.map(r=>r[1])].join("");
    console.log(webvttFile);
    // subtitleEncoder.encode(webvttFile)
    // webvttEntries = [];

    subtitleEncoder.encode(webvttFile);
    downloadStringAsFile("asd", webvttFile)
    // webvttEntries = webvttFile.slice(-1);

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


function downloadStringAsFile(filename, content) {
    // Create a Blob (e.g., text/plain) from your string
    const blob = new Blob([content], { type: 'text/plain' });
  
    // Create a temporary URL for that Blob
    const url = URL.createObjectURL(blob);
  
    // Create a hidden <a> element with a download attribute
    const a = document.createElement('a');
    a.style.display = 'none';
    a.href = url;
    a.download = filename; // e.g., 'myFile.txt'
  
    // Add it to the document and trigger a click
    document.body.appendChild(a);
    a.click();
  
    // Cleanup: revoke the ObjectURL and remove the element
    URL.revokeObjectURL(url);
    document.body.removeChild(a);
  }