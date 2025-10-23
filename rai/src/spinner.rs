/// Simple unicode spinner used while waiting for model responses.
#[derive(Debug, Clone)]
pub struct Spinner {
    frames: &'static [&'static str],
    index: usize,
}

impl Spinner {
    pub fn thinking() -> Self {
        // Braille spinner frames chosen for smooth animation.
        const FRAMES: &[&str] = &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
        Self {
            frames: FRAMES,
            index: 0,
        }
    }

    pub fn frame(&self) -> &'static str {
        self.frames[self.index]
    }

    pub fn tick(&mut self) {
        self.index = (self.index + 1) % self.frames.len();
    }

    pub fn reset(&mut self) {
        self.index = 0;
    }
}
