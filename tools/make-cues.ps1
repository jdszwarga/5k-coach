# Generates the spoken cue clips in /audio using a built-in Windows voice.
# Run from the project root:  powershell -ExecutionPolicy Bypass -File tools\make-cues.ps1
param([string]$Voice = 'Microsoft Zira Desktop', [int]$Rate = 0)

Add-Type -AssemblyName System.Speech
$out = Join-Path $PSScriptRoot '..\audio'
New-Item -ItemType Directory -Force $out | Out-Null

$cues = [ordered]@{
  'warmup'   = 'Warm up. Start with a brisk walk.'
  'run'      = 'Run.'
  'walk'     = 'Walk.'
  'lastrun'  = 'Last run. Finish strong.'
  'halfway'  = 'Halfway there.'
  'oneminute'= 'One minute left.'
  'cooldown' = 'Cool down. Easy walk.'
  'done'     = 'Workout complete. Great job!'
}

# 11025 Hz, 16-bit, mono: matches the sample rate the app renders workouts at.
$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(11025, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)

foreach ($k in $cues.Keys) {
  $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $s.SelectVoice($Voice)
  $s.Rate = $Rate
  $s.Volume = 100
  $path = Join-Path $out "$k.wav"
  $s.SetOutputToWaveFile($path, $fmt)
  $s.Speak($cues[$k])
  $s.Dispose()
  "{0,-10} {1,7:N0} bytes" -f $k, (Get-Item $path).Length
}
