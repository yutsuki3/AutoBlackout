# Third-party notices

AutoBlackout is released under the MIT License (see [LICENSE](LICENSE)). It has no third-party
dependencies: nothing from the projects below is compiled into it or vendored in this repository.

This file records the projects that informed it, how, and their license notices.

## How these projects relate to AutoBlackout

AutoBlackout was written independently, in Swift. Its functionality (turning the built-in display
off while an external display is connected, and restoring it when the external display goes away)
was informed by how the projects below behave:

- **[Lunar](https://github.com/alin23/Lunar)** by Alin Panaitiu: its "BlackOut" feature, which can
  turn a monitor or the built-in display off. Lunar's repository is MIT-licensed, but the code for its
  paid Pro features, including BlackOut, is encrypted in that repository and is not readable there.
  AutoBlackout therefore does not, and could not, include that code.
- **[screen-toggle](https://github.com/0xruth1ezz/screen-toggle)** by 0xruth1ezz: a small menu bar app
  that toggles the built-in display and restores it when the external monitors disconnect (MIT).

An AI coding assistant was used while building AutoBlackout, and it may have looked at the public source
of these projects. No code was intentionally copied from them. The private symbols involved
(`SLSConfigureDisplayEnabled`, `CGSConfigureDisplayEnabled`, `SLSGetDisplayList`) belong to macOS and are
documented in many public places.

Because that can't be ruled out completely, the copyright and permission notice that both projects
distribute is reproduced below, as the MIT License asks of anything that may contain portions of the
software. If you are the author of one of these projects and would like something changed here,
please open an issue.

AutoBlackout is an independent project. It is **not affiliated with, endorsed by, or supported by**
Lunar, Alin Panaitiu, or the author of screen-toggle. "Lunar" and "BlackOut" are the names of another
project and its feature.

## MIT License notices

Both projects distribute the following notice (screen-toggle's LICENSE file carries the same text and
copyright line as Lunar's).

### Lunar (https://github.com/alin23/Lunar)

```
MIT License

Copyright (c) 2018 Alin Panaitiu

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### screen-toggle (https://github.com/0xruth1ezz/screen-toggle)

```
MIT License

Copyright (c) 2018 Alin Panaitiu

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
