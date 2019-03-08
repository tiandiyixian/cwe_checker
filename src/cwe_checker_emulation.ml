open Core_kernel.Std
open Bap.Std
open Bap_primus.Std
open Bap_future.Std
open Graphlib.Std
open Monads.Std
open Format
open Ppx_jane

include Self()

let pp_id = Monad.State.Multi.Id.pp

module Machine = struct
  type 'a m = 'a
  include Primus.Machine.Make(Monad.Ident)
end
open Machine.Syntax

module Main = Primus.Machine.Main(Machine)
module Interpreter = Primus.Interpreter.Make(Machine)
module Linker = Primus.Linker.Make(Machine)
module Env = Primus.Env.Make(Machine)
module Lisp = Primus.Lisp.Make(Machine)
module Eval = Primus.Interpreter.Make(Machine)

(* event collection and reporting  *)

let collected_events = ref ([||])

let convert_location loc =
  match (Str.split (Str.regexp ":") loc) with
  | fst::snd::[] -> Int.of_string ("0x" ^ snd)
  | _ -> failwith "Could not parse location"

let convert_location_list loc_list =
  let locs = ref [] in
  Sexplib__Sexp_with_layout.List.iter loc_list ~f:(fun x -> locs := (convert_location @@ Sexp.to_string x)::(!locs));
  !locs

let map_id_to_location id loc_tbl =
  match Hashtbl.find loc_tbl id with
  | Some loc -> loc
  | _ -> failwith "Expected location in hashtbl but failed"

let rec pp_path locations =
  match locations with
  | [] -> printf "\n"
  | hd::[] -> printf "%x\n" hd
  | hd::tl -> printf "%x -> " hd; pp_path tl

(* TODO: Annotate events at TID location;
   TODO add checkers to cwe_checker that go through CFGs and dump warnings *)
let report_events _ =
  let location_tbl = Hashtbl.create ~hashable:String.hashable () in
  let incident_list = ref [] in
  Array.iter ~f:(fun (p, ev) ->
      begin
        match ev with
        |  Sexp.Atom _ -> printf "STRANGE\n"
        |  Sexp.List [Sexp.Atom location_id; Sexp.List location_list] -> Hashtbl.add location_tbl location_id (convert_location_list location_list);()
        |  Sexp.List incident -> match incident with
                                 | name::ids ->
                                    begin
                                    let incident_locations = ref [] in
                                    Sexplib__Sexp_with_layout.List.iter ids ~f:(fun id ->  incident_locations := (map_id_to_location (Sexp.to_string id) location_tbl)::(!incident_locations));
                                    let filtered_locs = Int.Set.to_list (Int.Set.of_list (List.concat !incident_locations)) in
                                       printf "%s " @@ Sexp.to_string name; pp_path filtered_locs
                                    end
                                 | __ -> failwith "Strange incident sexp encountered"
      end) !collected_events

let collect_events p ev =
  collected_events := Array.append !collected_events [|(p, ev)|]

(*********************)

let string_of_name = function
  | `symbol s -> s
  | `tid t -> Tid.to_string t
| `addr x -> Addr.string_of_value x

let entry_point_collector = object
  inherit [tid list] Term.visitor
  method! enter_term _ t entries =
    if Term.has_attr t Sub.entry_point
    then Term.tid t :: entries
    else entries
  end

let entry_points prog =
  entry_point_collector#run prog []

let all_subroutines prog =
  let entries = entry_points prog in
  let non_entry =
    let roots = Tid.Set.of_list entries in
    fun t -> if Set.mem roots t then None else Some (`tid t) in
  List.map entries ~f:(fun t -> `tid t) @
  Seq.to_list @@
  Seq.filter_map ~f:non_entry @@
  Graphlib.reverse_postorder_traverse (module Graphs.Callgraph) @@
    Program.to_graph prog

let exec x =
  Machine.current () >>= fun cid ->
  info "Fork %a: starting from the %s entry point"
    pp_id cid (string_of_name x);
  Machine.catch (Linker.exec x)
    (fun exn ->
       info "execution from %s terminated with: %s "
         (string_of_name x)
         (Primus.Exn.to_string exn);
       Machine.return ())

let rec run = function
  | [] ->
    info "all toplevel machines done, halting";
    Eval.halt >>=
    never_returns
  | x :: xs ->
    Machine.current () >>= fun pid ->
    Machine.fork ()    >>= fun () ->
    Machine.current () >>= fun cid ->
    if pid = cid
    then run xs
    else
      exec x >>= fun () ->
      Eval.halt >>=
      never_returns

let has_name name p =
  Primus.Observation.Provider.name p = name

let monitor_provider name ps =
  Primus.Observation.list_providers () |>
  List.find ~f:(has_name name) |> function
  | None -> invalid_argf "An unknown observation provider `%s'" name ()
  | Some p -> p :: ps

let parse_monitors =
  List.fold ~init:[] ~f:(fun ps name -> monitor_provider name ps)


module Monitor(Machine : Primus.Machine.S) = struct
    open Machine.Syntax

    let init () =
      parse_monitors ["incident"; "incident-location"] |>
      List.iter ~f:(fun m ->
          info "monitoring %s" (Primus.Observation.Provider.name m);
          Stream.observe (Primus.Observation.Provider.data m) (collect_events m));
      Machine.return ()
end


let main {Config.get=(!)} proj =
  Primus.Machine.add_component (module Monitor);
  begin
  let targets =  all_subroutines (Project.program proj) in
  Main.run ~envp:[||] ~args:[||] proj (run targets) |> function
  | (Primus.Normal,proj)
  | (Primus.Exn Primus.Interpreter.Halt,proj) ->
     info "Ok, we've terminated normally";
  | (Primus.Exn exn,proj) ->
     info "program terminated by a signal: %s" (Primus.Exn.to_string exn);
  end;
  report_events ();
  proj


 let deps = [
  "trivial-condition-form"
]

let () =
  Config.when_ready (fun conf -> Project.register_pass ~deps (main conf))