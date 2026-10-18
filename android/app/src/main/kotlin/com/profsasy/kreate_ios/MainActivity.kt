package com.profsasy.kreate_ios

import com.ryanheise.audioservice.AudioServiceActivity

// AudioServiceActivity shares the Flutter engine with the playback service,
// so the music goes on when the app leaves the screen.
class MainActivity : AudioServiceActivity()
