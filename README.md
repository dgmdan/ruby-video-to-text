# Video Transcription & Subtitle Generator

This script automates the process of extracting audio from a video, transcribing the speech using OpenAI's Whisper API, optionally translating the transcript using GPT-4, and generating SRT subtitles. It also allows you to add these subtitles (both original and translated) back into your video file.

## Features

- Extracts audio from video using `ffmpeg`.
- Splits audio for transcription if necessary.
- Generates word-level timestamped transcripts via OpenAI Whisper.
- Saves both the full transcript (as `.txt`) and SRT subtitles.
- Optionally translates subtitles into another language using GPT-4.
- Merges subtitles (original and translation) into the output video.
- Supports multiple languages.

## Requirements

- Ruby (3.x recommended)
- [FFmpeg](https://ffmpeg.org/) (must be available in `$PATH`)
- OpenAI API key in your environment as `OPENAI_API_KEY`

## Installation

1. Install system dependencies:
   ```sh
   sudo apt install ffmpeg
   ```
2. Install Ruby gems:
   ```sh
   gem install httparty optparse
   ```
3. Export your OpenAI API key:
   ```sh
   export OPENAI_API_KEY=your_api_key_here
   ```

## Options

- `-v`, `--video VIDEO_PATH`  
  Path to your video file. (required)

- `-l`, `--language LANGUAGE`  
  Source language code (default: `en`).

- `-t`, `--translate LANGUAGE`  
  Target language code for subtitle translation (optional).

- `-h`, `--help`  
  Show usage help.

### Example

Extract English subtitles and translate them to Spanish:

```sh
ruby transcribe.rb --video myvideo.mp4 --language en --translate es
```

## Output

- `transcription.txt`: Plain text transcript of the video (same directory as input video).
- `output_with_subtitles.mp4`: Video file with embedded subtitles.
  - Contains the original language and (if requested) the translation as selectable subtitle tracks.

## Notes

- Transcription and translation use OpenAI APIs, which may incur costs.
- Processing time depends on video length and API performance.
- For best results, use clear, high-quality audio.
- ChatGPT is a lot better at writing code than it is writing documentation in markdown.

**Contributions and issues welcome!**
