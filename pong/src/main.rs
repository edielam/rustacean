use libp2p::{
    development_transport,
    gossipsub::{Gossipsub, GossipsubConfig, GossipsubEvent, MessageAuthenticity, IdentTopic, IdentityTransform},
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

    // Define the ngrok bootstrap node's address and peer ID
    let bootstrap_peer_id: PeerId = "12D3KooWQmB5Ftfk3XS8PCEAsedFXGoa3rqnBMCC9P3xHSeqWqqG".parse()?;
    let bootstrap_addr: Multiaddr = "/dns4/0.tcp.ngrok.io/tcp/13095".parse()?;

    // Add the bootstrap node as a known peer
    swarm.behaviour_mut().add_explicit_peer(&bootstrap_peer_id);
    Swarm::dial(&mut swarm, bootstrap_addr)?;

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
