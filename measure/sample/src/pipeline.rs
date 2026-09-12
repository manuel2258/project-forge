//! Uses every dependency that matters for build weight, so a rebuild here is not trivial.

use crate::geometry::Point;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
pub struct Summary {
    pub count: usize,
    pub mean_magnitude: f64,
    pub matched: usize,
}

pub fn run(points: &[Point]) -> Summary {
    let total: f64 = points.par_iter().map(Point::magnitude).sum();
    let pattern = regex::Regex::new(r"^-?\d+\.\d{3}").expect("the pattern is a literal");
    let matched = points
        .par_iter()
        .filter(|point| pattern.is_match(&format!("{:.3}", point.x)))
        .count();

    Summary {
        count: points.len(),
        mean_magnitude: if points.is_empty() {
            0.0
        } else {
            total / points.len() as f64
        },
        matched,
    }
}
