use std::fs::File;

use clap::Parser;

///Search for pattern in a file and display the lines that contain it. More like grep
#[derive(Parser)]
struct Cli {
    pattern: String,
    path: std::path::PathBuf, 
}
fn main() {
    // let pattern = std::env::args().nth(1).expect("where is the pattern, bro?");
    // let path = std::env::args().nth(2).expect("Can't find your file man");

    let args = Cli::parse();
    //let content = std::fs::read_to_string(&args.path).expect("Yo what's in this file");
    let f = File::open(&args.path);
    let content = std::io::BufReader::new(f);
    
    for line in content.lines(){
        if line.contains(&args.pattern){
            println!("{}", line);
        }
    }
}
