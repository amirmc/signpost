open List

exception Invalid_addressables

(* IP's have two parts:
 * - The ip itself
 * - Who/what provides it. That could be local IP, or an IP provided by OpenVPN
 * etc.
 *)
type ip = IP of string * string

type port = Port of int

type srv = SRV of ip * port

(* TODO: Replace with whatever control channel we are using *)
type control_channel = ControlChannel of string

type addressable =
  | IPAddressInstance of ip
  | SRVInstance of srv

type goals = 
  | IPRecord
  | SRVRecord

type requirement =
  | Authentication
  | Encryption
  | Anonymity
  | Compression

(* a node represents a control channel with which we 
 * can communicate with a node 
 *)
type node = {
  name : string;
  control_channel : control_channel;
  ips : addressable list;
}

type tactic = {
  tactic_name : string;
  (* The tactic function works as follows:
   * It takes three addressable units:
   * - Start point (A)
   * - End point (B)
   * - Relay node (R) (can be a random node, or either of the start or endpoint)
   * It returns
   * - addressable entity that B can use to see A
   * - addressable entity that A can use to see B
   *)
  run : addressable -> addressable -> addressable -> (addressable * addressable);
  provides : requirement list
}

let (|>) a b = b a

let does_tactic_provide_reqs tactic reqs =
  try let _ = find (function req -> mem req tactic.provides) reqs in true
  with Not_found -> false

let tactics_providing_req reqs tactics =
  tactics
  |> filter (function tactic -> does_tactic_provide_reqs tactic reqs)

let str_of_addr address = match address with
  | IPAddressInstance(IP(address, source)) -> address ^ " (" ^ source ^ ")"
  | SRVInstance(SRV(IP(address, source), Port(port))) -> address ^ ":" ^
        (string_of_int port) ^ " (" ^ source ^ ")"

let str_of_node node =
  let first_addressable = hd node.ips in
  str_of_addr first_addressable

let rec str_of_tactics tactics = match tactics with
  | [] -> "No tactics used"
  | tactic::[] -> tactic.tactic_name
  | tactic::rest -> tactic.tactic_name ^ " over " ^ (str_of_tactics rest)

let output_results tactics a b =
  let addr_a = str_of_node a in
  let addr_b = str_of_node b in
  let str_tac = str_of_tactics tactics in
  Printf.printf "Found connection %s -> %s (%s)\n" addr_a addr_b str_tac

(*
 * This function takes a goal, a set of requirements, and a starting point.
 * It then tries as best as it can, to convert the starting point into something
 * satisfying all the requirements and that is the goal.
 *
 * More specifically:
 * - I have two names, A and B
 * I want:
 * - connectable ip of B
 * - the connection should be Encrypted
 * 
 * So goal:
 * - IP_address of B
 * Starting point:
 * - name of A 
 * - name of B
 * Requirements:
 * - Encrypted
 *)

let rec tactize (node_a, node_b) reqs nodes tactics used_tactics = match reqs with
  | [] -> output_results used_tactics node_a node_b
  | requirements ->
      tactics 
      |> tactics_providing_req requirements
      |> iter (fun tactic -> 
          execute_tactic tactic (node_a, node_b) reqs nodes tactics used_tactics)

and execute_tactic tactic (node_a, node_b) reqs nodes tactics used_tactics = 
  let new_used_tactics = tactic :: used_tactics in
  let new_req = (filter (fun r -> not (mem r tactic.provides)) reqs) in
  nodes 
  |> iter (fun node ->
      [(node_a, node_b);(node_b, node_a)]
      |> iter (fun (a,b) ->
          let addr_a, addr_b, addr_c = hd a.ips, hd b.ips, hd node.ips in
          let (new_a, new_b) = (tactic.run addr_a addr_b addr_c) in
          let updated_a = {a with ips = new_a :: a.ips} in
          let updated_b = {b with ips = new_b :: b.ips} in
          try tactize (updated_a, updated_b) new_req nodes tactics new_used_tactics
          with Invalid_addressables -> ())
  )

let test () =
  (* Create the nodes we have in our system *)
  let node1 = {
    name = "node A";
    control_channel = ControlChannel("ChannelA");
    ips = [IPAddressInstance(IP("10.0.0.1", "local"))]
  } in
  let node2 = {
    name = "node B";
    control_channel = ControlChannel("ChannelB");
    ips = [IPAddressInstance(IP("11.0.0.1", "local"))]
  } in
  let node3 = {
    name = "node C";
    control_channel = ControlChannel("ChannelC");
    ips = [IPAddressInstance(IP("12.0.0.1", "local"))]
  } in
  let nodes = [node1; node2; node3] in

  let reqs = [Anonymity;Authentication] in

  (* Currently the following tactics exist *)
  let tactics = [
    {
      tactic_name = "OpenVPN"; 
      run = (fun a b c -> match (a, b, c) with
        | IPAddressInstance(a), IPAddressInstance(b), IPAddressInstance(c) -> 
              SRVInstance(SRV(IP("149.0.12.1", "OpenVPN"), Port(1332))),
              SRVInstance(SRV(IP("123.0.10.3", "OpenVPN"), Port(1193)))
        | _ -> raise Invalid_addressables);
      provides = [Authentication; Compression; Encryption]
    };{
      tactic_name = "IPSec"; 
      run = (fun a b c -> match (a, b, c) with
        | IPAddressInstance(a), IPAddressInstance(b), IPAddressInstance(c) -> 
              IPAddressInstance(IP("209.0.123.1", "IPSec")),
              IPAddressInstance(IP("22.0.1.103", "IPSec"))
        | _ -> raise Invalid_addressables);
      provides = [Authentication; Encryption]
    };{
      tactic_name = "TCPCrypt"; 
      run = (fun a b c -> a, b);
      provides = [Encryption]
    };{
      tactic_name = "Iodine"; 
      run = (fun a b c -> match (a, b, c) with
        | IPAddressInstance(a), IPAddressInstance(b), IPAddressInstance(c) -> 
              IPAddressInstance(IP("14.0.123.1", "Iodine")),
              IPAddressInstance(IP("18.0.1.103", "Iodine"))
        | _ -> raise Invalid_addressables);
      provides = [Authentication]
    };{
      tactic_name = "Tor"; 
      run = (fun a b c -> match (a, b, c) with
        | IPAddressInstance(a), IPAddressInstance(b), IPAddressInstance(c) -> 
              SRVInstance(SRV(IP("14.0.123.1", "Tor"), Port(1332))),
              SRVInstance(SRV(IP("18.0.1.103", "Tor"), Port(1193)))
        | _ -> raise Invalid_addressables);
      provides = [Anonymity]
    }
  ] in

  (* Action GO! Find a way to connect the nodes :*)
  tactize (node1, node2) reqs nodes tactics []

let _ =  test ()
