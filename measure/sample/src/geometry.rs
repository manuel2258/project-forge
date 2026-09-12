//! Leaf module: the `leaf` measurement branch edits this and nothing else.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    pub fn magnitude(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}

pub fn ring(count: usize) -> Vec<Point> {
    (0..count)
        .map(|index| {
            let angle = index as f64 / count.max(1) as f64 * std::f64::consts::TAU;
            Point {
                x: angle.cos(),
                y: angle.sin(),
            }
        })
        .collect()
}
