// Copyright (c) 2026 sebiimaks. Distributed under the MIT license.
window.MathJax = {
    loader: {paths: {mathjax: 'js/mathjax'}, load: ['ui/safe']},
    tex: {inlineMath: [['$', '$'], ['\\(', '\\)'], ['$$', '$$'], ['\\((', '\\))']], maxBuffer: 16384, maxMacros: 1000},
    options: {
        enableMenu: false,
        safeOptions: {allow: {URLs: 'none', classes: 'none', cssIDs: 'none', styles: 'none'}}
    }
};
