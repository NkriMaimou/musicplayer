// server.js
const express = require("express");
const { spawn, execFileSync } = require("child_process");
const dfpwm = require("dfpwm"); // npm install dfpwm
const fs = require("fs");
const path = require("path");

const CACHE_DIR = path.join(__dirname, "cache");
if (!fs.existsSync(CACHE_DIR)) fs.mkdirSync(CACHE_DIR);

const app = express();
const PORT = 3000;

app.get("/", (req, res) => {
    res.setHeader("Content-Type", "text/plain; charset=utf-8");
    res.end("DFPWM backend online");
});

app.get("/musica.lua", (req, res) => {
    console.log("[update] musica.lua requested");
    res.type("text/plain").sendFile(path.join(__dirname, "musica.lua"));
});


// =====================================================
//  AUDIO CONVERTER
// =====================================================
app.get("/convert", (req, res) => {
    const url = req.query.url;
    if (!url) {
        res.status(400).end("Missing url parameter");
        return;
    }

    const id = url.split("v=")[1] || url;
    const cachePath = path.join(CACHE_DIR, id + ".dfpwm");

    if (fs.existsSync(cachePath)) {
        console.log("[cache] hit:", cachePath);
        return fs.createReadStream(cachePath).pipe(res);
    }

    console.log("[convert] URL:", url);

    const ytdlp = spawn("yt-dlp", [
        "-f", "bestaudio",
        "--audio-format", "wav",
        "-o", "-",
        url
    ]);

    ytdlp.on("error", err => {
        console.error("yt-dlp error:", err);
        res.status(500).end("yt-dlp failed");
    });

    const ffmpeg = spawn("ffmpeg", [
        "-i", "pipe:0",
        "-f", "s8",
        "-ac", "1",
        "-ar", "48000",
        "-af", "dynaudnorm",
        "pipe:1"
    ]);

    ffmpeg.on("error", err => {
        console.error("ffmpeg error:", err);
        res.status(500).end("ffmpeg failed");
    });

    ytdlp.stdout.pipe(ffmpeg.stdin);

    ytdlp.stderr.on("data", d => process.stderr.write("[yt-dlp] " + d));
    ffmpeg.stderr.on("data", d => process.stderr.write("[ffmpeg] " + d));

    const encoder = new dfpwm.Encoder();

    res.setHeader("Content-Type", "application/octet-stream");

    const file = fs.createWriteStream(cachePath);

    ffmpeg.stdout.on("data", chunk => {
        try {
            const encoded = encoder.encode(chunk);
            file.write(encoded);
            res.write(encoded);
        } catch (e) {
            console.error("encode error:", e);
        }
    });

    ffmpeg.on("close", () => {
        file.end();
        res.end();
    });

    ytdlp.on("close", code => {
        console.log("yt-dlp exited with code", code);
    });
});


// =====================================================
//  SHORT YOUTUBE ID ROUTE
//
//  Example:
//  /7AUpzxEhtCY
//
//  Automatically becomes:
//  https://www.youtube.com/watch?v=7AUpzxEhtCY
// =====================================================
app.get("/:id", (req, res, next) => {
    const id = req.params.id;

    // YouTube video IDs are normally exactly 11 characters
    if (!/^[a-zA-Z0-9_-]{11}$/.test(id)) {
        return next();
    }

    const url = `https://www.youtube.com/watch?v=${id}`;
    const cachePath = path.join(CACHE_DIR, id + ".dfpwm");

    console.log("[short] YouTube ID:", id);
    console.log("[short] URL:", url);

    // -----------------------------
    // CACHE
    // -----------------------------
    if (fs.existsSync(cachePath)) {
        console.log("[cache] hit:", cachePath);
        res.setHeader("Content-Type", "application/octet-stream");
        return fs.createReadStream(cachePath).pipe(res);
    }

    // -----------------------------
    // YT-DLP
    // -----------------------------
    console.log("[convert] Starting yt-dlp...");

    const ytdlp = spawn("yt-dlp", [
        "-f", "bestaudio",
        "--audio-format", "wav",
        "-o", "-",
        url
    ]);

    ytdlp.on("error", err => {
        console.error("yt-dlp error:", err);

        if (!res.headersSent) {
            res.status(500).end("yt-dlp failed");
        }
    });

    // -----------------------------
    // FFMPEG
    // -----------------------------
    const ffmpeg = spawn("ffmpeg", [
        "-i", "pipe:0",
        "-f", "s8",
        "-ac", "1",
        "-ar", "48000",
        "-af", "dynaudnorm",
        "pipe:1"
    ]);

    ffmpeg.on("error", err => {
        console.error("ffmpeg error:", err);

        if (!res.headersSent) {
            res.status(500).end("ffmpeg failed");
        }
    });

    ytdlp.stdout.pipe(ffmpeg.stdin);

    ytdlp.stderr.on("data", d =>
    process.stderr.write("[yt-dlp] " + d)
    );

    ffmpeg.stderr.on("data", d =>
    process.stderr.write("[ffmpeg] " + d)
    );

    // -----------------------------
    // DFPWM ENCODER
    // -----------------------------
    const encoder = new dfpwm.Encoder();

    res.setHeader("Content-Type", "application/octet-stream");

    const file = fs.createWriteStream(cachePath);

    ffmpeg.stdout.on("data", chunk => {
        try {
            const encoded = encoder.encode(chunk);

            file.write(encoded);
            res.write(encoded);

        } catch (e) {
            console.error("encode error:", e);
        }
    });

    ffmpeg.on("close", code => {
        console.log("[ffmpeg] exited with code", code);

        file.end();

        if (!res.writableEnded) {
            res.end();
        }
    });

    ytdlp.on("close", code => {
        console.log("[yt-dlp] exited with code", code);
    });
});


// =====================================================
//  PURE NODE.JS NFV VIDEO CONVERTER
// =====================================================
app.get("/convertVideo", async (req, res) => {
    const url = req.query.url;
    const resolution = req.query.resolution || "128x96";
    const fps = parseInt(req.query.fps || "125");

    if (!url) return res.status(400).end("Missing url parameter");

    const id = url.split("v=")[1] || url;
    const videoPath = path.join(CACHE_DIR, id + ".mp4");
    const nfvPath = path.join(
        CACHE_DIR,
        id + "_nfp16v3_" + resolution + "_" + fps + ".nfv"
    );

    // ---- CACHE CHECK ----
    if (fs.existsSync(nfvPath)) {
        console.log("[cache] video hit:", nfvPath);
        return fs.createReadStream(nfvPath).pipe(res);
    }

    console.log("[convertVideo] URL:", url);

    // ---- DOWNLOAD VIDEO ----
    const downloadSucceeded = await new Promise(resolve => {
        const ytdlp = spawn("yt-dlp", [
            "--no-playlist",
            "-f", "bestvideo[height<=360]/bestvideo",
            "-o", videoPath,
            url
        ]);

        ytdlp.stderr.on("data", d =>
        process.stderr.write("[yt-dlp] " + d)
        );

        ytdlp.on("error", err => {
            console.error("yt-dlp error:", err);
            resolve(false);
        });

        ytdlp.on("close", code => {
            console.log("yt-dlp exited with code", code);
            resolve(code === 0 && fs.existsSync(videoPath));
        });
    });

    if (!downloadSucceeded) {
        return res.status(502).end("Video download failed");
    }

    let outputFps = fps;
    try {
        const frameRate = execFileSync("ffprobe", [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=r_frame_rate",
            "-of", "default=noprint_wrappers=1:nokey=1",
            videoPath
        ], { encoding: "utf8" }).trim();
        const [numerator, denominator] = frameRate.split("/").map(Number);
        if (numerator > 0 && denominator > 0) {
            outputFps = Math.max(1, Math.min(fps, Math.round(numerator / denominator)));
        }
    } catch (error) {
        console.error("ffprobe error:", error.message);
    }

    // ---- FFMPEG RAW RGB24 PIPE ----
    const [w, h] = resolution.split("x").map(Number);
    const frameBytes = w * h * 3;

    const ffmpeg = spawn("ffmpeg", [
        "-i", videoPath,
        "-vf", `scale=${resolution}:flags=lanczos`,
        "-f", "rawvideo",
        "-pix_fmt", "rgb24",
        "pipe:1"
    ]);

    ffmpeg.stderr.on("data", d =>
    process.stderr.write("[ffmpeg] " + d)
    );

    // ---- WRITE NFV FILE ----
    const out = fs.createWriteStream(nfvPath);
    const header = `${w} ${h} ${outputFps}\n`;

    res.setHeader("Content-Type", "text/plain; charset=utf-8");
    res.setHeader("Cache-Control", "no-cache, no-transform");
    res.setHeader("Connection", "keep-alive");
    res.flushHeaders();
    res.write(header);
    out.write(header);

    let buffer = Buffer.alloc(0);
    let responseBackpressured = false;

    ffmpeg.stdout.on("data", chunk => {
        buffer = Buffer.concat([buffer, chunk]);

        while (buffer.length >= frameBytes) {
            const frame = buffer.slice(0, frameBytes);
            buffer = buffer.slice(frameBytes);

            const encodedFrame = convertRGBtoNFP(frame, w, h) + "\n";
            out.write(encodedFrame);
            if (!res.destroyed && !responseBackpressured && !res.write(encodedFrame)) {
                responseBackpressured = true;
                ffmpeg.stdout.pause();
                res.once("drain", () => {
                    responseBackpressured = false;
                    ffmpeg.stdout.resume();
                });
                break;
            }
        }
    });

    ffmpeg.on("error", err => {
        console.error("ffmpeg error:", err);
    });

    res.on("close", () => {
        console.log("[convertVideo] Client disconnected; continuing cache conversion");
        responseBackpressured = false;
        ffmpeg.stdout.resume();
    });

    ffmpeg.on("close", code => {
        out.end();

        if (code !== 0) {
            fs.rmSync(nfvPath, { force: true });
            if (!res.headersSent) res.status(502).end("Video conversion failed");
            else res.end();
            return;
        }

        console.log("[convertVideo] Finished:", nfvPath);

        if (!res.writableEnded) res.end();
    });
});


// =====================================================
//  RGB → NFP CONVERTER
// =====================================================
function convertRGBtoNFP(rgb, w, h) {
    const output = Buffer.allocUnsafe(w * h);
    const pixels = w * h;

    for (let i = 0; i < pixels; i++) {
        const r = rgb[i * 3];
        const g = rgb[i * 3 + 1];
        const b = rgb[i * 3 + 2];

        const lookupKey =
        (r >> 3) * 1024 +
        (g >> 3) * 32 +
        (b >> 3);

        output[i] = NFP_LOOKUP[lookupKey];
    }

    for (let i = 0; i < output.length; i++) {
        output[i] = HEX_DIGITS.charCodeAt(output[i]);
    }

    return output.toString("ascii");
}


const CC_COLORS = [
    [240, 240, 240],
[242, 178, 51],
[229, 127, 216],
[153, 178, 242],
[222, 222, 108],
[127, 204, 25],
[242, 178, 204],
[76, 76, 76],
[153, 153, 153],
[76, 153, 178],
[178, 102, 229],
[51, 102, 204],
[127, 102, 76],
[87, 166, 78],
[204, 76, 76],
[25, 25, 25]
];

const HEX_DIGITS = "0123456789abcdef";

const NFP_LOOKUP = new Uint8Array(32 * 32 * 32);

for (let red = 0; red < 32; red++) {
    for (let green = 0; green < 32; green++) {
        for (let blue = 0; blue < 32; blue++) {

            const r = red * 8 + 4;
            const g = green * 8 + 4;
            const b = blue * 8 + 4;

            let nearest = 0;
            let nearestDistance = Infinity;

            for (
                let colorIndex = 0;
            colorIndex < CC_COLORS.length;
            colorIndex++
            ) {
                const color = CC_COLORS[colorIndex];

                const redDistance = r - color[0];
                const greenDistance = g - color[1];
                const blueDistance = b - color[2];

                const distance =
                redDistance * redDistance +
                greenDistance * greenDistance +
                blueDistance * blueDistance;

                if (distance < nearestDistance) {
                    nearestDistance = distance;
                    nearest = colorIndex;
                }
            }

            NFP_LOOKUP[
                red * 1024 +
                green * 32 +
                blue
            ] = nearest;
        }
    }
}


// =====================================================
//  SERVER
// =====================================================
app.listen(PORT, "0.0.0.0", () => {
    console.log("DFPWM backend listening on port", PORT);
});
