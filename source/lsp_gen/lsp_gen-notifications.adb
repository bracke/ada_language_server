------------------------------------------------------------------------------
--                         Language Server Protocol                         --
--                                                                          --
--                     Copyright (C) 2022-2023, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with VSS.Strings;

with LSP_Gen.Puts; use LSP_Gen.Puts;

with LSP_Gen.Configurations;

package body LSP_Gen.Notifications is

   use type VSS.Strings.Virtual_String;

   procedure Write_Receivers
     (Model : LSP_Gen.Meta_Models.Meta_Model;
      From  : LSP_Gen.Configurations.Message_Direction);

   procedure Write_Readers
     (Model : LSP_Gen.Meta_Models.Meta_Model;
      From  : LSP_Gen.Configurations.Message_Direction);

   procedure Write_Writers
     (Model : LSP_Gen.Meta_Models.Meta_Model;
      From  : LSP_Gen.Configurations.Message_Direction);

   procedure Write_Notification_Types
     (Model : LSP_Gen.Meta_Models.Meta_Model;
      From  : LSP_Gen.Configurations.Message_Direction);

   function Prefix
     (From : LSP_Gen.Configurations.Message_Direction)
      return VSS.Strings.Virtual_String is
        (VSS.Strings.To_Virtual_String
          (case From is
              when LSP_Gen.Configurations.From_Both => "Base",
              when LSP_Gen.Configurations.From_Client => "Server",
              when LSP_Gen.Configurations.From_Server => "Client"));

   ------------------------------
   -- Write_Notification_Types --
   ------------------------------

   procedure Write_Notification_Types
     (Model : LSP_Gen.Meta_Models.Meta_Model;
      From  : LSP_Gen.Configurations.Message_Direction)
   is
      use all type LSP_Gen.Configurations.Message_Direction;
      Kind : constant VSS.Strings.Virtual_String := Prefix (From);
      Name : constant VSS.Strings.Virtual_String := Kind & "_Notification";
   begin
      for J of Model.Notifications loop
         if Model.Message_Direction (J) in From | From_Both then
            Put_Lines (Model.License_Header, "--  ");
            New_Line;

            if Model.Notification (J).params.Is_Set then
               Put_Line ("with LSP.Structures;");
            end if;

            New_Line;
            Put ("package LSP.");
            Put (Name);
            Put ("s.");
            Put (Model.Message_Name (J));
            Put_Line (" is");
            Put_Line ("pragma Preelaborate;");
            New_Line;
            Put ("type Notification is new LSP.");
            Put (Name);
            Put ("s.");
            Put (Name);
            Put_Line (" with record");

            if Model.Notification (J).params.Is_Set then
               Put ("Params : LSP.Structures.");
               Put (Model.Notification (J).params.Value.Union.reference.name);
               Put_Line (";");
            else
               Put_Line ("null;");
            end if;

            Put_Line ("end record;");
            New_Line;

            Put ("overriding procedure Visit_");
            Put (Kind);
            Put_Line ("_Receiver");
            Put_Line ("(Self  : Notification;");
            Put ("Value : in out LSP.");
            Put (Name);
            Put ("_Receivers.");
            Put (Name);
            Put_Line ("_Receiver'Class);");
            New_Line;

            Put_Line ("end;");
            New_Line;

            --  Package body
            Put_Lines (Model.License_Header, "--  ");
            New_Line;
            Put ("package body LSP.");
            Put (Name);
            Put ("s.");
            Put (Model.Message_Name (J));
            Put_Line (" is");
            New_Line;

            Put ("overriding procedure Visit_");
            Put (Kind);
            Put_Line ("_Receiver");
            Put_Line ("(Self  : Notification;");
            Put ("Value : in out LSP.");
            Put (Name);
            Put ("_Receivers.");
            Put (Name);
            Put_Line ("_Receiver'Class) is");
            Put_Line ("begin");
            Put ("Value.On_");
            Put (Model.Message_Name (J));
            Put ("_Notification");

            if Model.Notification (J).params.Is_Set then
               Put (" (Self.Params)");
            end if;

            Put_Line (";");
            Put_Line ("end;");
            New_Line;

            Put_Line ("end;");
            New_Line;

         end if;
      end loop;
   end Write_Notification_Types;

   -------------------
   -- Write_Readers --
   -------------------

   procedure Write_Readers
     (Model : LSP_Gen.Meta_Models.Meta_Model;
      From  : LSP_Gen.Configurations.Message_Direction)
   is
      use all type LSP_Gen.Configurations.Message_Direction;

      Kind : constant VSS.Strings.Virtual_String := Prefix (From);
      First : Boolean := True;
      Index : Positive := 1;
   begin
      Put_Lines (Model.License_Header, "--  ");
      New_Line;
      Put_Line ("with Minimal_Perfect_Hash;");
      Put_Line ("with LSP.Inputs;");
      Put_Line ("with LSP.Input_Tools;");
      Put_Line ("with LSP.Structures;");
      New_Line;

      for J of Model.Notifications loop
         if Model.Message_Direction (J) in From | From_Both then
            Put ("with LSP.");
            Put (Kind);
            Put ("_Notifications.");
            Put (Model.Message_Name (J));
            Put_Line (";");
         end if;
      end loop;

      New_Line;

      Put ("package body LSP.");
      Put (Kind);
      Put_Line ("_Notification_Readers is");
      New_Line;

      Put_Line ("package Method_Map is new Minimal_Perfect_Hash ([");
      for J of Model.Notifications loop
         if Model.Message_Direction (J) in From | From_Both then
            if First then
               First := False;
            else
               Put (", ");
            end if;

            Put ("""");
            Put (J);
            Put ("""");
         end if;
      end loop;

      Put_Line ("]);");
      New_Line;
      Put_Line ("procedure Initialize is begin Method_Map.Initialize; end;");
      New_Line;

      for J of Model.Notifications loop
         if Model.Message_Direction (J) in From | From_Both then
            Put ("procedure Read_");
            Put (Model.Message_Name (J));

            if Model.Notification (J).params.Is_Set then
               Put_Line (" is new LSP.Input_Tools.Read_Notification");
               Put ("(LSP.Structures.");
               Put (Model.Notification (J).params.Value.Union.reference.name);
               Put (", """);
               Put (J);

               if Model.Notification (J).params.Value.Union.reference.name
                 = "LSPAny"
               then
                  Put (""", LSP.Input_Tools.Read_");
               else
                  Put (""", LSP.Inputs.Read_");
               end if;
               Put (Model.Notification (J).params.Value.Union.reference.name);
               Put_Line (");");
            else
               Put (" (Handler : in out ");
               Put_Line ("VSS.JSON.Pull_Readers.JSON_Pull_Reader'Class;");
               Put ("Method : VSS.Strings.Virtual_String := """);
               Put (J);
               Put_Line (""")");
               Put_Line ("is null;");
            end if;

            New_Line;
         end if;
      end loop;

      Put_Line ("function Read_Notification (Input : ");
      Put_Line ("in out VSS.JSON.Pull_Readers.JSON_Pull_Reader'Class;");
      Put_Line ("Method : VSS.Strings.Virtual_String)");
      Put ("return LSP.");
      Put (Kind);
      Put ("_Notifications.");
      Put (Kind);
      Put_Line ("_Notification'Class is");
      Put_Line ("Index : constant Natural := Method_Map.Get_Index (Method);");
      Put_Line ("begin");
      Put_Line ("case Index is");

      for J of Model.Notifications loop
         if Model.Message_Direction (J) in From | From_Both then
            Put ("when ");
            Put (Index);
            Index := Index + 1;
            Put (" =>  --  ");
            Put_Line (J);

            Put ("return Result : LSP.");
            Put (Kind);
            Put ("_Notifications.");
            Put (Model.Message_Name (J));
            Put_Line (".Notification do");
            Put ("Read_");
            Put (Model.Message_Name (J));
            Put_Line (" (Input");

            if Model.Notification (J).params.Is_Set then
               Put (", Result.Params");
            end if;

            Put_Line (");");
            Put_Line ("end return;");
            New_Line;
         end if;
      end loop;

      Put_Line ("when others =>");
      Put_Line ("return raise Program_Error with ""Unknown method"";");
      Put_Line ("end case;");
      Put_Line ("end;");

      Put_Line ("end;");

   end Write_Readers;

   ---------------------
   -- Write_Receivers --
   ---------------------

   procedure Write_Receivers
     (Model : LSP_Gen.Meta_Models.Meta_Model;
      From  : LSP_Gen.Configurations.Message_Direction)
   is
      use all type LSP_Gen.Configurations.Message_Direction;

      Name : constant VSS.Strings.Virtual_String :=
        Prefix (From) & "_Notification_Receiver";
   begin
      Put_Lines (Model.License_Header, "--  ");
      New_Line;

      if From /= From_Both then
         Put_Line ("with LSP.Base_Notification_Receivers;");
      end if;

      Put_Line ("with LSP.Structures;");
      New_Line;
      Put ("package LSP.");
      Put (Name);
      Put_Line ("s is");
      Put_Line ("pragma Preelaborate;");
      New_Line;
      Put ("type ");
      Put (Name);
      Put (" is limited interface");

      if From /= From_Both then
         Put
           (" and LSP.Base_Notification_Receivers.Base_Notification_Receiver");
      end if;

      Put_Line (";");
      New_Line;

      for J of Model.Notifications loop
         if Model.Message_Direction (J) = From then
            Put ("procedure On_");
            Put (Model.Message_Name (J));
            Put_Line ("_Notification");
            Put ("(Self : in out ");
            Put (Name);

            if Model.Notification (J).params.Is_Set then
               Put_Line (";");
               Put ("Value : LSP.Structures.");
               Put (Model.Notification (J).params.Value.Union.reference.name);
            end if;

            Put_Line (") is null;");
            Put_Lines
              (Model.Notification (J).documentation.Split_Lines, "   --  ");
            New_Line;
         end if;
      end loop;

      Put_Line ("end;");
   end Write_Receivers;

   -----------------
   -- Write_Types --
   -----------------

   procedure Write
     (Model : LSP_Gen.Meta_Models.Meta_Model)
   is
      use all type LSP_Gen.Configurations.Message_Direction;
   begin
      Write_Readers (Model, From_Server);
      Write_Readers (Model, From_Client);
      Write_Writers (Model, From_Both);
      Write_Writers (Model, From_Server);
      Write_Writers (Model, From_Client);
      Write_Receivers (Model, From_Both);
      Write_Receivers (Model, From_Client);
      Write_Receivers (Model, From_Server);
      Write_Notification_Types (Model, From_Client);
      Write_Notification_Types (Model, From_Server);
   end Write;

   -------------------
   -- Write_Writers --
   -------------------

   procedure Write_Writers
     (Model : LSP_Gen.Meta_Models.Meta_Model;
      From  : LSP_Gen.Configurations.Message_Direction)
   is
      use all type LSP_Gen.Configurations.Message_Direction;

      Kind : constant VSS.Strings.Virtual_String := Prefix (From);
      Name : constant VSS.Strings.Virtual_String :=
        Kind & "_Notification_Writer";
   begin
      Put_Lines (Model.License_Header, "--  ");
      New_Line;

      if From = From_Both then
         Put_Line ("with VSS.JSON.Content_Handlers;");
      else
         Put_Line ("with LSP.Base_Notification_Writers;");
      end if;

      Put_Line ("with LSP.Structures;");
      Put ("with LSP.");
      Put (Kind);
      Put_Line ("_Notification_Receivers;");
      New_Line;
      Put ("package LSP.");
      Put (Name);
      Put_Line ("s is");
      Put_Line ("pragma Preelaborate;");
      New_Line;
      Put ("type ");
      Put_Line (Name);

      if From = From_Both then
         Put ("(Output : access VSS.JSON.Content_Handlers");
         Put_Line (".JSON_Content_Handler'Class)");
         Put ("is new ");
      else
         Put ("is new LSP.Base_Notification_Writers.Base_Notification_Writer");
         Put (" and ");
      end if;

      Put ("LSP.");
      Put (Kind);
      Put ("_Notification_Receivers.");
      Put (Kind);
      Put_Line ("_Notification_Receiver");
      Put_Line ("with null record;");
      New_Line;

      for J of Model.Notifications loop
         if Model.Message_Direction (J) = From then
            Put ("overriding procedure On_");
            Put (Model.Message_Name (J));
            Put_Line ("_Notification");
            Put ("(Self : in out ");
            Put (Name);

            if Model.Notification (J).params.Is_Set then
               Put_Line (";");
               Put ("Value : LSP.Structures.");
               Put (Model.Notification (J).params.Value.Union.reference.name);
            end if;

            Put_Line (");");
            New_Line;
         end if;
      end loop;

      Put_Line ("end;");

      Put_Lines (Model.License_Header, "--  ");
      New_Line;

      if From /= From_Both then
         Put_Line ("with VSS.JSON.Content_Handlers;");
      end if;

      Put_Line ("with LSP.Output_Tools;");
      Put_Line ("with LSP.Outputs;");
      New_Line;

      Put ("package body LSP.");
      Put (Name);
      Put_Line ("s is");
      New_Line;

      for J of Model.Notifications loop
         if Model.Message_Direction (J) = From then
            Put ("overriding procedure On_");
            Put (Model.Message_Name (J));
            Put_Line ("_Notification");
            Put ("(Self : in out ");
            Put (Name);

            if Model.Notification (J).params.Is_Set then
               Put_Line (";");
               Put ("Value : LSP.Structures.");
               Put (Model.Notification (J).params.Value.Union.reference.name);
            end if;

            Put_Line (") is");
            Put_Line ("begin");
            Put
              ("LSP.Output_Tools.Write_Start_Notification"
               & " (Self.Output.all, """);
            Put (J);
            Put_Line (""");");

            if Model.Notification (J).params.Is_Set then
               declare
                  Tipe : constant VSS.Strings.Virtual_String :=
                    Model.Notification (J).params.Value.Union.reference.name;
               begin
                  Put_Line ("Self.Output.Key_Name (""params"");");

                  if Tipe = "LSPAny" then
                     Put ("LSP.Output_Tools.Write_");
                  else
                     Put ("LSP.Outputs.Write_");
                  end if;

                  Put (Tipe);
                  Put_Line (" (Self.Output.all, Value);");
               end;
            end if;

            Put_Line ("Self.Output.End_Object;");
            Put_Line ("end;");
            New_Line;
         end if;
      end loop;

      Put_Line ("end;");

   end Write_Writers;

end LSP_Gen.Notifications;
