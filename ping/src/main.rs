use libp2p::{
    development_transport,
    gossipsub::{Gossipsub, GossipsubConfig, GossipsubEvent, MessageAuthenticity, IdentityTransform, IdentTopic},
    identity, PeerId, Swarm,
    Multiaddr,
    swarm::SwarmEvent,
};
use tokio::io::{self, AsyncBufReadExt};
use tokio_stream::StreamExt;
use std::error::Error;

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    // Generate a key pair for authentication
    let local_key = identity::Keypair::generate_ed25519();
    let local_peer_id = PeerId::from(local_key.public());
    println!("Local peer id: {:?}", local_peer_id);

    // Create a transport
    let transport = development_transport(local_key.clone()).await?;

    // Create a Gossipsub instance
    let gossipsub_config = GossipsubConfig::default();
    let topic = IdentTopic::new("chat");
    let mut gossipsub: Gossipsub<IdentityTransform> = Gossipsub::new(MessageAuthenticity::Signed(local_key), gossipsub_config)?;
    gossipsub.subscribe(&topic)?;

    // Create a Swarm to manage the network
    let mut swarm = {
        let behaviour = gossipsub;
        Swarm::new(transport, behaviour, local_peer_id.clone())
    };

    // Add a listening address
    let listen_addr: Multiaddr = "/ip4/0.0.0.0/tcp/0".parse()?;
    Swarm::listen_on(&mut swarm, listen_addr)?;

    // Await for the listeners to be set up
    let mut listeners_printed = false;

    // Handle incoming messages and user input
    let mut stdin = io::BufReader::new(io::stdin()).lines();
    loop {
        tokio::select! {
            line = stdin.next_line() => {
                if let Some(line) = line? {
                    let message = line.as_bytes();
                    swarm.behaviour_mut().publish(topic.hash(), message)?;
                }
            }
            event = swarm.next() => {
                if let Some(event) = event {
                    match event {
                        SwarmEvent::NewListenAddr { address, .. } => {
                            if !listeners_printed {
                                println!("Listening on {:?}", address);
                                listeners_printed = true;
                            }
                        }
                        SwarmEvent::Behaviour(GossipsubEvent::Message { message, .. }) => {
                            println!("Received: {:?}", String::from_utf8_lossy(&message.data));
                        }
                        _ => {}
                    }
                }
            }
        }
    }
}
