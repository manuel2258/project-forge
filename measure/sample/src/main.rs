//! A sample workload for the measurement harness. It exists to compile: a dependency tree
//! worth caching and a final link worth measuring. See measure/sample/README.md.

mod geometry;
mod pipeline;
mod report;

use clap::Parser;

#[derive(Parser)]
#[command(about = "sample workload for forge's measurement harness")]
struct Options {
    /// How many points to push through the pipeline.
    #[arg(long, default_value_t = 10_000)]
    points: usize,
}

fn main() {
    let options = Options::parse();
    let points = geometry::ring(options.points);
    let summary = pipeline::run(&points);
    println!("{}", report::render(&summary));
}
