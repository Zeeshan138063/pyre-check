(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core


module BooleanOperator : sig
  type operator =
    | And
    | Or
  [@@deriving compare, eq, sexp, show, hash]

  type 'expression t = {
    left: 'expression;
    operator: operator;
    right: 'expression;
  }
  [@@deriving compare, eq, sexp, show, hash]
end

module Record : sig
  module Argument : sig
    type 'expression record = {
      name: (Identifier.t Node.t) option;
      value: 'expression;
    }
    [@@deriving compare, eq, sexp, show, hash]
  end

  module Access : sig
    type 'expression access =
      | Call of (('expression Argument.record) list) Node.t
      | Identifier of Identifier.t
    [@@deriving compare, eq, sexp, show, hash]

    type 'expression record = ('expression access) list
    [@@deriving compare, eq, sexp, show, hash]

    type 'expression general_access_record =
      | SimpleAccess of 'expression record
      | ExpressionAccess of { expression: 'expression; access: 'expression record }
    [@@deriving compare, eq, sexp, show, hash]
  end

  module ComparisonOperator : sig
    type operator =
      | Equals
      | GreaterThan
      | GreaterThanOrEquals
      | In
      | Is
      | IsNot
      | LessThan
      | LessThanOrEquals
      | NotEquals
      | NotIn
    [@@deriving compare, eq, sexp, show, hash]

    type 'expression record = {
      left: 'expression;
      operator: operator;
      right: 'expression;
    }
    [@@deriving compare, eq, sexp, show, hash]
  end

  module UnaryOperator : sig
    type operator =
      | Invert
      | Negative
      | Not
      | Positive
    [@@deriving compare, eq, sexp, show, hash]

    type 'expression record = {
      operator: operator;
      operand: 'expression;
    }
    [@@deriving compare, eq, sexp, show, hash]
  end
end

module Name : sig
  module Attribute : sig
    type 'expression t = {
      base: 'expression;
      attribute: Identifier.t;
    }
    [@@deriving compare, eq, sexp, show, hash]
  end

  type 'expression t =
    | Attribute of 'expression Attribute.t
    | Identifier of Identifier.t
  [@@deriving compare, eq, sexp, show, hash]
end

module Call : sig
  module Argument : sig
    type 'expression t = {
      name: (Identifier.t Node.t) option;
      value: 'expression;
    }
    [@@deriving compare, eq, sexp, show, hash]
  end

  type 'expression t = {
    callee: 'expression;
    arguments: ('expression Argument.t) list;
  }
  [@@deriving compare, eq, sexp, show, hash]
end

module Lambda : sig
  type 'expression t = {
    parameters: ('expression Parameter.t) list;
    body: 'expression;
  }
  [@@deriving compare, eq, sexp, show, hash]
end

module Ternary : sig
  type 'expression t = {
    target: 'expression;
    test: 'expression;
    alternative: 'expression;
  }
  [@@deriving compare, eq, sexp, show, hash]
end

module Dictionary : sig
  type 'expression entry = {
    key: 'expression;
    value: 'expression;
  }
  [@@deriving compare, eq, sexp, show, hash]

  type 'expression t = {
    entries: ('expression entry) list;
    keywords: 'expression list;
  }
  [@@deriving compare, eq, sexp, show, hash]
end

module Comprehension : sig
  type 'expression generator = {
    target: 'expression;
    iterator: 'expression;
    conditions: 'expression list;
    async: bool;
  }
  [@@deriving compare, eq, sexp, show, hash]

  type ('element, 'expression) t = {
    element: 'element;
    generators: ('expression generator) list;
  }
  [@@deriving compare, eq, sexp, show, hash]
end

module Starred : sig
  type 'expression t =
    | Once of 'expression
    | Twice of 'expression
  [@@deriving compare, eq, sexp, show, hash]
end

module StringLiteral : sig
  module Substring : sig
    type kind =
      | Literal
      | Format
    [@@deriving compare, eq, sexp, show, hash]

    type t = { value: string; kind: kind }
    [@@deriving compare, eq, sexp, show, hash]
  end

  type 'expression kind =
    | String
    | Bytes
    | Format of 'expression list
    | Mixed of Substring.t list

  and 'expression t = {
    value: string;
    kind: 'expression kind;
  }
  [@@deriving compare, eq, sexp, show, hash]

  val create: ?bytes: bool -> ?expressions: 'expression list -> string -> 'expression t

  val create_mixed: Substring.t list -> 'expression t
end

type expression =
  | Access of t Record.Access.general_access_record
  | Await of t
  | BooleanOperator of t BooleanOperator.t
  | Call of t Call.t
  | ComparisonOperator of t Record.ComparisonOperator.record
  | Complex of float
  | Dictionary of t Dictionary.t
  | DictionaryComprehension of ((t Dictionary.entry), t) Comprehension.t
  | Ellipsis
  | False
  | Float of float
  | Generator of (t, t) Comprehension.t
  | Integer of int
  | Lambda of t Lambda.t
  | List of t list
  | ListComprehension of (t, t) Comprehension.t
  | Name of t Name.t
  | Set of t list
  | SetComprehension of (t, t) Comprehension.t
  | Starred of t Starred.t
  | String of t StringLiteral.t
  | Ternary of t Ternary.t
  | True
  | Tuple of t list
  | UnaryOperator of t Record.UnaryOperator.record
  | Yield of t option

and t = expression Node.t
[@@deriving compare, eq, sexp, show, hash]

and expression_t = t
[@@deriving compare, eq, sexp, show, hash]

module Argument : sig
  include module type of struct include Record.Argument end

  type t = expression_t Record.Argument.record
  [@@deriving compare, eq, sexp, show, hash]
end

module Access : sig
  include module type of struct include Record.Access end

  type t = expression_t Record.Access.record
  [@@deriving compare, eq, sexp, show, hash]

  type general_access = expression_t Record.Access.general_access_record
  [@@deriving compare, eq, sexp, show, hash]

  module Set: Set.S with type Elt.t = t
  module Map: Map.S with type Key.t = t
  module SerializableMap: SerializableMap.S with type key = t
  include Hashable with type t := t

  val create: string -> t
  val create_from_identifiers: Identifier.t list -> t

  val combine: expression_t -> t -> general_access
  val expression: ?location: Location.t -> t -> expression_t

  val sanitized: t -> t
  val equal_sanitized: t -> t -> bool
  val pp_sanitized: Format.formatter -> t -> unit
  val show_sanitized: t -> string

  val delocalize: t -> t
  val delocalize_qualified: t -> t

  val is_strict_prefix: prefix: t -> t -> bool
  val drop_prefix: t -> prefix: t -> t
  (* Returns all but the last component in the access. *)
  val prefix: t -> t
  val last: t -> expression_t access option

  val call
    :  ?arguments: Argument.t list
    -> location: Location.t
    ->  name: string
    -> unit
    -> t

  type call = {
    callee: string;
    arguments: Argument.t list;
  }
  (* If `call` is a simple function call, evaulates to the name and arguments. *)
  val name_and_arguments: call: t -> call option

  (* Calls like `__add__` have backups that are called on exceptions. *)
  val backup: name: t -> Identifier.t option
  (* Some calls are redirected to method calls, e.g. `repr(x)` will call
     `x.__repr__()`. *)
  val redirect
    :  arguments: Argument.t list
    -> location: Location.t
    -> name: t
    -> general_access option

  val is_assert_function: t -> bool
end

module ComparisonOperator : sig
  include module type of struct include Record.ComparisonOperator end

  type t = expression_t Record.ComparisonOperator.record
  [@@deriving compare, eq, sexp, show, hash]

  val override: t -> expression_t option
end

module UnaryOperator : sig
  include module type of struct include Record.UnaryOperator end

  type t = expression_t Record.UnaryOperator.record
  [@@deriving compare, eq, sexp, show, hash]

  val override: t -> expression_t option
end

val negate: t -> t

val normalize: t -> t

val convert: t -> t

val create_name_from_identifiers: (Identifier.t Node.t) list -> expression_t Name.t

val create_name: location: Location.t -> string -> expression_t Name.t

val name_to_identifiers: expression_t Name.t -> (Identifier.t list) option

val is_simple_name: expression_t Name.t -> bool

val delocalize: t -> t

val delocalize_qualified: t -> t

val exists_in_list : ?match_prefix:bool -> expression_list: t list -> string -> bool

val pp : Format.formatter -> t -> unit

val show : t -> string

val show_sanitized: t -> string

val pp_sanitized: Format.formatter -> t -> unit

val pp_expression_list : Format.formatter -> t list -> unit

val pp_expression_access_list : Format.formatter -> Access.t -> unit

val pp_expression_argument_list : Format.formatter -> (t Argument.record) list -> unit

val pp_expression_parameter_list :
  Format.formatter -> expression Node.t Parameter.t list -> unit
