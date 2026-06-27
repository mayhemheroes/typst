#![no_main]

// Historical OSS-Fuzz / mayhemheroes `compile` target, restored for target parity with the
// archived original (archive/better-lists shipped a `compile` fuzz target). It compiles the input
// as a Typst source into a PagedDocument and renders the first page — the classic "does the full
// compile+render pipeline survive arbitrary source?" harness. Implemented against the current API
// (typst::compile::<PagedDocument> + RenderOptions), reusing the shared FuzzWorld from the crate.

use libfuzzer_sys::fuzz_target;
use typst_fuzz::FuzzWorld;
use typst_layout::PagedDocument;
use typst_render::RenderOptions;

fuzz_target!(|text: &str| {
    let world = FuzzWorld::new(text);
    if let Ok(document) = typst::compile::<PagedDocument>(&world).output {
        if let Some(page) = document.pages().first() {
            std::hint::black_box(typst_render::render(page, &RenderOptions::default()));
        }
    }
    comemo::evict(10);
});
